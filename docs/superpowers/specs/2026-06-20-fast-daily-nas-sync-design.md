# Design: Fast Daily Cross-Cluster NAS Sync

- **Date:** 2026-06-20
- **Status:** Approved (design); pending implementation plan
- **Scope:** Refines the `incremental` path of `cross-cluster-rsync-guide-v3.13-consolidated.md` so the daily sync of a ~6 TB / ~7.4 M-file dataset is fast, while keeping a one-time initial bulk sync.
- **Approach:** "A" from brainstorming — Parallel initial + Incremental daily + Weekly parallel reconcile backstop.

---

## 1. Problem

Pulling ~6 TB / ~7.4 M files from source NAS B to target NAS A with plain rsync is slow **not because of bytes transferred** (daily change ≈ 0.17 % ≈ ~12 K files / a few GB) but because rsync walks the entire directory tree on **both** ends every run to build and compare the file list. At 7.4 M files the dominant cost is NFS metadata round-trips (readdir + stat), which scales with *total* file count, not *changed* file count.

**Goal:** make the daily run scale with the change rate, not the dataset size, while staying correct for an accumulating archive.

## 2. Locked decisions

These were confirmed during brainstorming and drive the design:

1. **Initial vs daily are separate tracks.** Initial bulk sync may take hours (one-time); daily must be fast.
2. **Change pattern = scattered edits** across the tree → folder-scoped syncing is insufficient; a change-list (manifest) is required.
3. **No delete propagation.** Target is an accumulating archive. `find -newer` is therefore fully correct (its inability to detect deletions does not matter). Snapshot diffing is **not** required — it remains a future speed-only upgrade (Approach C).
4. **Stale/missing manifest → skip + alert** (do not fall back to a blind full sync, which would re-introduce the slow path daily).
5. **Consistency guarantee = "any missed file is corrected within ≤ 7 days"** via a weekly parallel reconcile. A bidirectional client→server acknowledgment protocol is explicitly out of scope (YAGNI).
6. **Source NAS is writable** for a small state directory, so the manifest can be written into an excluded dir on the source and served by the existing rsync daemon (no extra mounts / RWX PVC needed).

## 3. Non-goals

- Delete/rename mirroring to the target.
- Snapshot-based change detection (`zfs diff` / NetApp SnapDiff) — documented as a future upgrade only.
- Same-day guaranteed consistency after a failed run (the weekly reconcile is the guarantee).
- Any change to the client image build, CRLF-safety, or Istio sidecar-quit machinery (reused unchanged).

---

## 4. Architecture

One client image, three K8s objects, plus one server-side manifest job. Behavior selected by `SYNC_MODE` per the guide's "two orthogonal axes" model.

| Track | Cluster | K8s object | `SYNC_MODE` | Cadence | Walks whole tree? |
|---|---|---|---|---|---|
| Initial bulk | A | Deployment | `parallel` | Once, at bring-up | Yes (one-time, acceptable) |
| **Daily** | A | CronJob | `incremental` | Daily (or every 2 h) | **No** — client uses `--files-from` |
| Weekly reconcile | A | CronJob | `parallel` | Weekly, off-hours | Yes (correctness backstop) |
| Manifest generator | B | CronJob | n/a | Ahead of daily window | Yes, server-side, overlapped & parallelized |

The daily client never walks the tree. The unavoidable full walk is moved to the **server**, run **asynchronously ahead of time**, done **once on one side** (vs rsync's two-sided walk), and **parallelized**.

---

## 5. Component specs

### 5.1 Track 1 — Initial bulk sync (reuse guide §10B, no logic change)

- `Deployment` + `SYNC_MODE=parallel`, **no** `activeDeadlineSeconds`.
- `PARALLEL_WORKERS` tuned to the CPU limit; effective ceiling bounded by the daemon's `max connections = 20`.
- On `=== COMPLETE` in logs, tear down the Deployment and cut over to the daily CronJob (guide §10B.2).
- This run also **seeds the marker** so the first daily manifest is a true delta (see 5.3d).

### 5.2 Track 2 — Daily incremental client (refines guide §8.4)

Flow of `nas-sync-incremental.sh`:

1. **Pre-flight** (unchanged): password file readable, remote reachable, local target mounted.
2. **Fetch manifest** explicitly by name: `rsync -a <module>/.sync-state/manifest.txt /tmp/manifest.raw`.
3. **Freshness guard (new):**
   - Manifest must exist and end with a completion sentinel line `# COMPLETE <epoch> <count>` (see 5.3c).
   - Read `<epoch>`; compare to the client's last-consumed epoch stored at `<target>/.sync-state/last-consumed-manifest` (absent file = "never consumed" = treat as `0`, so the first daily run proceeds).
   - **If manifest missing, has no sentinel, or `<epoch>` ≤ last-consumed →** log a distinct `ERROR: manifest stale/missing — skipping run`, **exit non-zero** so the Job is marked `Failed` (the alert signal), and make **no** changes to the target. (Adjustable: wire existing Job-status / log-scrape alerting to this.)
4. **First-run signal:** if the manifest's single content line is `FULL_SYNC`, do one full pull (or rely on Track 1 having filled the target — then this is skipped).
5. **Sync:** strip comment/sentinel lines (`grep -v '^#'`) into `/tmp/manifest.clean`, then
   `rsync -a --whole-file --partial --files-from=/tmp/manifest.clean <module>/ <target>/`.
   - `--files-from` makes rsync go straight to the listed paths (auto-creating parent dirs) — **no tree recursion**.
   - `--whole-file` kept: scattered small files, delta-diff CPU not worthwhile over a fast link.
   - **No `--delete`** (no-delete invariant).
6. **On success only:** write `<epoch>` to `<target>/.sync-state/last-consumed-manifest`.

**Client state:** `<target>/.sync-state/last-consumed-manifest` (target NAS, client has rw; persists across CronJob pods). Prevents acting twice on the same manifest and detects a stalled manifest job.

### 5.3 Server-side manifest generator (rewrite of guide §4.3 `generate-manifest.sh`)

Runs as the Cluster B manifest CronJob. Behavior:

**a) Parallelized walk.** Enumerate top-level entries of `$SOURCE_PATH`; fan out N workers (`xargs -P`, same pattern as the parallel sync script). Each worker, run from `$SOURCE_PATH` as cwd, executes `find <topdir> -newer "$MARKER" -type f` so output paths are already **relative to the module root** (i.e. `topdir/sub/file`), matching what `--files-from` needs. A separate pass handles top-level loose files (`find . -maxdepth 1 -newer "$MARKER" -type f`). Worker outputs go to per-worker temp files, concatenated in order.

**b) Conservative marker (fixes the latent data-loss bug in the guide).** Capture `CANDIDATE = scan-start timestamp` (`touch CANDIDATE`) **before** walking. Advance the persisted `MARKER` to `CANDIDATE` **only after** the manifest is fully and atomically published (step c). Because `CANDIDATE` is the scan *start*, any file changed *during* the scan/transfer is re-included next cycle — redundant at worst, never missed.

**c) Atomic publish + completion sentinel.** Write all paths to `manifest.txt.tmp`, append a final line `# COMPLETE <epoch> <count>`, then `mv` it over `manifest.txt` (atomic within the same filesystem). Only then advance the marker. The client's freshness guard keys off this sentinel, so a half-written manifest can never be consumed — this removes the guide's fragile ":50 vs :00" timing dependency.

**d) First run.** No marker → write a manifest whose content line is `FULL_SYNC`, **append the same `# COMPLETE <epoch> <count>` sentinel** (so it passes the client freshness guard like any other manifest), then create the marker. (If Track 1 already filled the target, seed the marker from Track 1's completion time so the first daily manifest is a real delta instead of `FULL_SYNC`.)

**e) Prune.** The find must prune excluded paths so they never enter the manifest: `.snapshot`/`.snapshots`/`.zfs`/`@Recently-Snapshot`/`@Recycle`/`#recycle`/`@eaDir`/`@tmp` **and** the `.sync-state/` dir itself.

### 5.4 Weekly reconcile (new CronJob, Cluster A, reuses `parallel` mode)

- `CronJob` + `SYNC_MODE=parallel`, e.g. `schedule: "0 2 * * 0"`.
- Full bilateral comparison → self-heals **any** drift: files missed because a daily run failed after the marker advanced, partial transfers, etc.
- This is the mechanism that delivers the "≤ 7 days" guarantee and lets the daily path stay simple (no ack protocol).
- Still **no `--delete`**.

### 5.5 State & storage topology

| Artifact | Location | Written by | Read by |
|---|---|---|---|
| `last-sync-marker` (+ `.candidate`) | Cluster B state PVC (guide §6.1, RWO) | Manifest CronJob | Manifest CronJob |
| `manifest.txt` (+ `.tmp`) | `<source>/.sync-state/manifest.txt` (source NAS, excluded dir) | Manifest CronJob | Daily client (via existing `nas-data` module) |
| `last-consumed-manifest` | `<target>/.sync-state/last-consumed-manifest` (target NAS) | Daily client (on success) | Daily client |

The manifest lives on the source NAS (writable per decision #6), so the **existing** rsync daemon serves it via the existing `nas-data` module — no RWX PVC, no extra mounts, no new module.

### 5.6 Config changes to existing files

- **`rsyncd.conf` module exclude (guide §5.2)** and **client `rsync-exclude.txt` (guide §9A.1):** add `.sync-state/` so the data sync ignores the state dir. (The client still fetches the manifest *explicitly* by name, which is unaffected by excludes.)
- **Manifest CronJob:** source NFS mount must be `readOnly: false` (it writes `.sync-state/`).
- **Daily CronJob `backoffLimit`:** set low (e.g. `0`) — retrying a stale-manifest skip won't help; let the next scheduled run handle it.

---

## 6. Data flow — one daily cycle

```
(server, ahead of window)                     (client, daily window)
manifest CronJob:                              daily CronJob (incremental):
  touch CANDIDATE                                fetch nas-data/.sync-state/manifest.txt
  parallel find -newer MARKER  ──► manifest.tmp  sentinel present & epoch > last-consumed?
  append "# COMPLETE epoch n"                       no  → ERROR + exit non-zero (alert), no change
  mv → manifest.txt (atomic)                        yes → rsync --files-from=<changed> (no walk)
  mv CANDIDATE → MARKER                                   on success → write last-consumed=epoch
```

## 7. Failure modes

| Failure | Behavior | Net effect |
|---|---|---|
| Manifest stale/missing/incomplete | Client skips, logs ERROR, exits non-zero (alert) | No change; retries next cycle |
| Client sync fails mid-run | `last-consumed` not advanced; same manifest re-consumed next run; conservative server marker re-includes mid-scan changes | Self-corrects next cycle; worst case caught by weekly reconcile |
| Server `find` overruns the window | Client consumes previous complete manifest (sentinel guard); never reads half-written file | Catches up next cycle |
| Changes skewed to one huge folder | Parallel find less balanced but still correct | Weekly reconcile covers any residual gap |
| Marker advanced but client never succeeds (e.g. days down) | Those files absent from future manifests | Weekly parallel reconcile restores them (≤ 7 days) |

## 8. Consistency guarantee

The daily incremental path is **fast but best-effort**; the **weekly parallel reconcile** provides the correctness guarantee: the target converges to the source (additively — no deletes) within at most 7 days, regardless of daily-run failures.

---

## 9. Files to change / create

**Cluster B (server):**
- Rewrite `scripts/generate-manifest.sh` — parallel walk, conservative marker, atomic publish + sentinel, prune (5.3).
- `configmap-rsyncd.yaml` — add `.sync-state/` to module exclude (5.6).
- Manifest CronJob YAML — confirm source mount `readOnly: false`; tune schedule for lead time (5.6, 7-scheduling).

**Cluster A (client):**
- Refine `scripts/nas-sync-incremental.sh` — explicit manifest fetch, freshness guard, comment-strip, client-state write (5.2).
- `configmap-exclude.yaml` — add `.sync-state/` (5.6).
- `cronjob-client.yaml` — daily, `SYNC_MODE=incremental`, `backoffLimit: 0` (5.6).
- New `cronjob-reconcile.yaml` — weekly, `SYNC_MODE=parallel` (5.4).
- Initial `deployment-client.yaml` — `SYNC_MODE=parallel`, no deadline (5.1, reuse §10B).

**Docs:**
- Update the guide's §12 ("Choosing Sync Mode") to reflect this three-track design and the manifest/marker/sentinel contract.

## 10. Verification plan

- **Manifest correctness:** seed marker, touch a known set of files, run the job, assert the manifest lists exactly those paths (relative to module root) + the sentinel; assert marker advanced only after publish.
- **Freshness guard:** point client at (a) missing manifest, (b) sentinel-less file, (c) already-consumed epoch → assert skip + non-zero exit + no target change in all three.
- **Happy path:** changed files appear on target; `last-consumed` updated; unrelated files untouched.
- **No-delete invariant:** guide §11 "Verify No-Delete" test still passes for daily and weekly.
- **CRLF guard:** rebuilt scripts pass the existing `head -1 ... | cat -A` shebang check.

## 11. Future upgrades (out of scope now)

- **Approach C — snapshot-diff manifest:** if NAS B is later confirmed ZFS/NetApp, swap the `find -newer` body of the manifest generator for `zfs diff` / SnapDiff. Interface (produces module-root-relative paths + sentinel) is unchanged, so the client and scheduling are untouched. Detect type via `kubectl exec deploy/nas-sync-server -n ea-pmc -- sh -c 'stat -f -c %T /mnt/nas-source; mount | grep nas-source'`.
- **Client-ack marker:** if same-day consistency is ever required, replace the weekly-reconcile guarantee with a client→server ack (writable state module) so the marker advances only on confirmed client success.
