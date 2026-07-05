# v3.15 Design — Validate & Harden the Cross-Cluster Rsync Approach

**Date:** 2026-07-05
**Status:** Approved (brainstorming complete; pending implementation plan)
**Target:** `cross-cluster-rsync-guide-v3.13-consolidated.md` (layered after the in-flight v3.14 work lands)

## 1. Motivation

Pre-production due diligence: before running the v3.13/v3.14 design at real scale
(~7.4M folders, ~0.17% change rate), confirm whether a more powerful approach exists,
and address the two stated reliability worries:

1. **Silent missed changes** — the mtime-based manifest quietly skipping files, letting
   the target drift from the source unnoticed.
2. **Jobs failing/hanging** — CronJob failures that require babysitting or go unnoticed.

## 2. Constraints (confirmed with the user)

- **NAS access:** NFS exports only. No admin access to either NAS; everything must run
  as pods in the two Kubernetes clusters.
- **Network:** the Istio ingress gateway on port 8787 is the *only* permitted cross-site
  channel. Fixed policy; no direct route/VPN possible.
- **Encryption:** the cross-site link is trusted — cleartext rsyncd is acceptable.
- **Semantics:** one-way (NAS B → NAS A), deletions must never propagate, target-only
  files preserved. Intentional policy, not a deferral.

## 3. Evaluation verdict: keep the rsync architecture

Alternatives researched (2025–2026 state of the art) and why each is rejected:

| Alternative | Rejected because |
|---|---|
| ZFS send/receive, btrfs send, TrueNAS replication | Needs NAS admin access + matching filesystems + direct network path; produces an exact mirror (deletes propagate — violates no-delete). |
| Vendor replication (SnapMirror, Synology Snapshot Replication, QNAP RTRR/HBS) | Same: NAS admin + matched vendors + direct NAS-to-NAS path; snapshot-based ones are exact mirrors. |
| lsyncd / inotify-based real-time sync | inotify is kernel-local and cannot observe changes on an NFS mount (lsyncd issues #288, #401). Would have to run on NAS B itself. |
| Syncthing | Same inotify limitation over NFS → full periodic rescans of the whole tree; `ignoreDelete` is warned against by Syncthing's own docs; receive-only folders with extra local files stay permanently "out of sync". Worst fit. |
| rclone `copy --max-age --no-traverse` | Same change-detection cost class as the manifest, weaker POSIX metadata fidelity (ownership, hardlinks, symlinks), and time-window detection is gap-prone after failed runs where the marker-file approach self-heals. Lateral move. |
| Resilio Connect / Datadobi (commercial) | Real-time detection also degrades to scheduled scans over NFS; licensing cost only justified toward 100M+ files or minutes-level RPO. Named escape hatch, not needed now. |
| MinIO/object-storage replication | Requires re-architecting the application off NFS. |

**Conclusion:** at this intersection of constraints, the server-side `find -newer`
manifest + `--files-from` rsync pull is a sound, near-state-of-the-art design.
Change detection classes: (1) paired full walk, (2) single-side walk producing a change
list, (3) snapshot/event diff. Class 3 is fundamentally cheaper but every class-3 option
fails a hard constraint above. The current design is the right shape for class 2.
We therefore **keep the architecture and harden it** — three additions, no new
infrastructure, no new tools, no new images beyond rebuilding the existing two.

All fixed conventions are preserved: port 8787, namespace `ea-pmc`, no-delete,
console-only logging, `--whole-file`, CRLF guards, `SYNC_MODE` dispatch, state under
`.nas-sync-state/` on the source NAS.

A key topology fact shapes the design: **the client cannot walk the source tree
locally** — it only speaks rsyncd protocol through the Istio gateway. Any full source
walk (chunk generation, like manifest generation today) must run on Cluster B next to
the NFS mount. This is why fpart/fpsync are not used directly (they assume local/SSH
source access); their *chunking idea* is reimplemented server-side instead.

## 4. Addition 1 — Verify mode (`SYNC_MODE=verify`)

**Attacks:** silent missed changes.

A drift-*detection* pass that counts and reports differences without transferring.
Repair remains the reconcile's job; verify only reports.

Two tiers, selected by `VERIFY_MODE=meta|checksum|both` (default `meta`):

- **Tier 1 — metadata verify (cheap, default):** `rsync -a --dry-run --itemize-changes`
  over the whole tree. Compares size+mtime, transfers nothing. Catches everything the
  incremental could miss *except* mtime-preserved content changes. Cost ≈ one paired
  tree walk.
- **Tier 2 — sampled checksum verify (rotating slice):** each run picks a deterministic
  slice of top-level dirs — `hash(dirname) % VERIFY_SLICES == (week_number % VERIFY_SLICES)`
  — and runs `--checksum --dry-run` on that slice only. Each run pays ~1/`VERIFY_SLICES`
  of the full read cost; full-tree byte coverage takes `VERIFY_SLICES` runs (with the
  default of 13: one quarter at weekly cadence, ~13 months at the monthly default —
  run tier 2 weekly, or lower `VERIFY_SLICES`, if faster coverage is wanted). Catches
  mtime-preserved corruption. A full `--checksum` pass reads every byte on both NAS
  and is deliberately not the default.

**Behavior:**

- Output: one parseable result line, e.g.
  `VERIFY RESULT mode=meta drift=142 checked=7412330 elapsed=3812s`.
- Exit 0 if `drift <= VERIFY_FAIL_THRESHOLD` (default 0), else exit 1 → the Job shows
  `Failed` in `kubectl get jobs`, making drift visible instead of silent.
- Pure `--dry-run`: never transfers, never deletes.
- Scheduled monthly, placed right after the weekly reconcile completes (tree at rest,
  so expected drift ≈ 0).
- New script `nas-sync-verify.sh` in the client image + new CronJob manifest.

## 5. Addition 2 — Chunked parallel reconcile

**Attacks:** performance + skew (one oversized top-level directory serializing the
weekly reconcile under the current top-level-folder split).

**Server side — new `generate-chunks.sh` on Cluster B**, run by a new weekly CronJob
scheduled ~2h before the client's reconcile (same offset idea as the manifest's `:50`):

- Full `find` walk of the NFS mount (NFS-local, the cheapest place to walk), emitting
  relative paths.
- Splits the list by count into `CHUNK_COUNT` files (default 24 — deliberately more
  chunks than workers so fast workers keep pulling; fpart's core trick):
  `.nas-sync-state/chunks/chunk-000.txt … chunk-023.txt` + `chunks.meta`
  (chunk count, total files, generation timestamp).
- Same safety idiom as the manifest generator: write to a temp dir, atomic `mv` into
  place, `concurrencyPolicy: Forbid`, orphan cleanup on start.

**Client side — `nas-sync-parallel.sh` upgraded:**

- First fetch `chunks.meta`. If present and fresh (within `CHUNK_MAX_AGE`, default 24h)
  → **chunked path**: `xargs -P $PARALLEL_WORKERS` over the chunk files, each worker
  running `rsync --files-from=chunk-NNN.txt`.
- If missing or stale → **fall back to the existing top-level split unchanged**
  (mirrors the manifest→FULL_SYNC fallback philosophy: a failed chunk job degrades to
  today's behavior, never breaks the reconcile).
- Per-worker failures don't abort the run; failed chunk numbers are collected, reported
  in the final status line, and the run exits nonzero if any chunk failed.

**Accepted trade-offs:** the weekly full walk on Cluster B is new load, but it replaces
client-side `--list-only` discovery over the wire and lands on the cheapest side.
Chunk lists at 7.4M+ entries total a few hundred MB on the source NAS; the guide notes
this and includes a cleanup line. Chunks live under `.nas-sync-state/` — already
writable, already client-excluded, no new mounts or PVCs.

## 6. Addition 3 — Sync status file

**Attacks:** jobs failing/hanging silently.

- `dispatch-sync.sh` gains a wrapper: after the mode script finishes, write
  `.nas-sync-status/last-run` on **NAS A** (the target mount — always writable,
  survives pods):
  `ts=2026-07-05T02:00:14Z mode=incremental exit=0 files=12483 elapsed=418s host=<pod>`
  plus `last-success` (updated only on exit 0). Atomic `mv` writes. Excluded from
  verify/reconcile comparisons.
- Written by the dispatcher, so all four modes (standard/parallel/incremental/verify)
  get it for free.
- §13 documents the staleness check —
  `cat /mnt/nas-target/.nas-sync-status/last-success` from any pod with the PVC —
  with the rule of thumb: older than 2× the CronJob interval = investigate.
- Stays inside the console-only-logging convention: no Prometheus/webhook dependency,
  but any external monitor can poll the file later.
- A status-write failure logs a warning but never fails the sync.

## 7. Error-handling summary

Every new path degrades to existing behavior:

| Failure | Result |
|---|---|
| Chunk job failed / chunks stale | Reconcile falls back to top-level split (today's behavior) |
| Verify finds drift | Job exits nonzero — visible, no data touched (dry-run only) |
| Status file write fails | Warning logged; sync outcome unaffected |

No new failure mode can make replication worse than today.

## 8. Guide integration (self-referential bookkeeping)

| Artifact | Action |
|---|---|
| `nas-sync-verify.sh`, `generate-chunks.sh` | New sections; added to both Dockerfiles' COPY + dos2unix + CRLF-guard lists |
| `nas-sync-parallel.sh`, `dispatch-sync.sh` | Updated in place (chunked path + fallback; status-file wrapper) |
| CronJob manifests | New: verify (monthly, Cluster A), chunk generator (weekly, Cluster B); reconcile schedule note updated |
| §11 test plan | New test entries: verify run, chunked reconcile run, chunk-fallback case, status-file check |
| §13 troubleshooting | New entries: drift > 0, chunks stale/fallback triggered, status file stale |
| §14 File Checklist | All new scripts/manifests listed with section numbers |
| "What This Consolidates" table | New capability rows tagged v3.15 |
| Filename/version | Follows whatever v3.14 does at landing; v3.15 additions recorded in the consolidates table either way |

All new fenced code blocks stay copy-paste-ready: valid shell/YAML, LF endings,
placeholders (`your-registry.example.com`, `ISTIO_EXTERNAL_IP_HERE`) intact and
marked `◄ MODIFY`.

## 9. Testing

Per §11 conventions (manual test jobs against real clusters):

1. `kubectl create job --from=cronjob/nas-sync-verify test-verify` — expect
   `VERIFY RESULT` line, exit 0 on an at-rest tree; then touch a file on NAS B only
   and expect drift ≥ 1 / exit 1.
2. Chunked reconcile: run chunk generator, then reconcile; confirm workers consume
   chunk files (log line names the chunk) and the run completes.
3. Fallback: delete `chunks.meta` on the source NAS, rerun reconcile; confirm it logs
   the fallback and uses the top-level split.
4. Status file: after any test job, confirm `.nas-sync-status/last-run` and
   `last-success` exist on NAS A with correct fields; confirm a forced-failure run
   updates `last-run` but not `last-success`.
5. CRLF guard: `head -1` each new script through `cat -A` — expect `#!/bin/bash$`.

## 10. Out of scope

- Transit encryption (user confirmed trusted link; if policy changes, TLS at the
  gateway or stunnel is the known path).
- Deletion propagation (intentionally unwanted).
- Commercial tools, object-storage re-architecture, NAS-native replication (blocked
  by constraints; documented above as conditions under which they'd win).
