# Cross-Cluster NAS Sync — Architecture Review

**Date:** 2026-07-22
**Reviewed:** `cross-cluster-rsync-guide-v3.14-consolidated.md` (and the v3.13 predecessor,
`docs/superpowers/specs/2026-07-05-rsync-hardening-v315-design.md`, and
`docs/superpowers/plans/2026-07-05-rsync-hardening-v315.md`)
**Outcome:** architecture validated and kept; 12 defects found and fixed in
`cross-cluster-rsync-guide-v3.15-consolidated.md`.

---

## 1. Verdict

**Keep the rsync architecture. It is the right class of solution for these constraints.**

The design pulls one-way from NAS B to NAS A across two Kubernetes clusters, using an rsync
daemon on the source fronted by an Istio TCP gateway on port 8787, with a server-side
`find`-generated change list feeding `rsync --files-from` on the client.

Change detection has three implementation classes:

| Class | Method | Cost | Available here? |
|---|---|---|---|
| 1 | Paired full walk (plain `rsync -a`) | Walk both sides every run | Yes — this is `standard`/`parallel` mode |
| 2 | Single-side walk producing a change list | Walk one side; transfer only listed paths | Yes — this is `incremental` mode |
| 3 | Snapshot or event diff (ZFS send, inotify, vendor replication) | Near-zero detection cost | **No** — every option fails a hard constraint |

Class 3 is fundamentally cheaper and would be the obvious answer with different constraints.
It is unavailable here, and the reasons are structural rather than a matter of effort:

| Alternative | Blocked by |
|---|---|
| ZFS send/receive, btrfs send, TrueNAS replication | Needs NAS admin access, matching filesystems, and a direct network path. Produces an exact mirror, so deletions propagate — violates the no-delete policy. |
| Vendor replication (SnapMirror, Synology Snapshot Replication, QNAP RTRR/HBS) | Same: NAS admin, matched vendors, direct NAS-to-NAS path. Snapshot-based variants are exact mirrors. |
| lsyncd / inotify | inotify is kernel-local and cannot observe changes made on an NFS mount. Would have to run on NAS B itself, which is not accessible. |
| Syncthing | Same inotify limitation over NFS, so it degrades to full periodic rescans. `ignoreDelete` is warned against by Syncthing's own documentation, and receive-only folders holding extra local files stay permanently "out of sync" — which is the steady state here by design. |
| rclone `copy --max-age --no-traverse` | Same detection cost class as the manifest, with weaker POSIX metadata fidelity (ownership, hardlinks, symlinks). A lateral move. |
| Resilio Connect, Datadobi | Real-time detection also degrades to scheduled scans over NFS. Licensing cost is justified toward 100M+ files or minutes-level RPO, neither of which applies. |
| Object storage replication (MinIO etc.) | Requires re-architecting the application off NFS. |

This table is condensed from the alternatives analysis in
`docs/superpowers/specs/2026-07-05-rsync-hardening-v315-design.md` §3. That analysis is sound and
this review concurs with it rather than repeating the research.

**One topology fact drives everything else:** the client cannot walk the source tree. It speaks
only the rsyncd protocol through the Istio gateway. Any full enumeration of the source must run
on Cluster B, next to the NFS mount. This is why fpart/fpsync cannot be used directly — they
assume local or SSH access to the source — and why their chunking idea is reimplemented
server-side in v3.15 instead.

**v3.14's stateless lookback window is a genuine improvement over v3.13's marker file.** There is
no source-side write state that can be corrupted or lost, the overlap between runs is explicit and
tunable per target, and one `find` walk serves every target. Keep it. This is why the v3.15
proposal's Addition 4 (`SYNC_ID` marker directories) is not carried forward — see §5.

The problems found are in implementation detail and operability, not in the shape of the design.

---

## 2. What mtime-based change detection can and cannot see

This is the honest limit of the whole approach and it belongs in front of any operator. The
`incremental` mode transfers exactly the paths listed in the manifest, and the manifest is built
from `find -type f -printf '%T@ %P\n'` filtered by an mtime threshold.

**Reliably caught:**

- New files
- Modified file contents (any write updates mtime)
- Files whose mtime was explicitly touched forward

**Never caught by `incremental` — repaired only by the weekly `parallel` reconcile:**

| Missed change | Why | Consequence until reconcile |
|---|---|---|
| **A file moved or renamed** | `mv` within a filesystem preserves the file's mtime, so the new path never enters the manifest | Target lacks the new path. Because `--delete` is correctly banned, it also keeps a stale copy at the old path — the target now holds a duplicate. |
| **A new empty directory** | The manifest lists `-type f` only | Directory absent on target |
| **A new symlink** | Same — `-type l` is not matched | Symlink absent on target |
| **Directory mode or ownership change** | Directories are never listed | Target keeps old metadata |
| **Content changed with mtime preserved** | Deliberate `touch -r`, some restore tools, some rsync-based ingest | Undetectable by any metadata comparison; needs a checksum pass |
| **Silent corruption on either side** | No metadata changes | Same — needs a checksum pass |

**This makes the weekly `parallel` reconcile a required compensating control, not an optional
extra.** In v3.14 it existed only as a prose note telling the operator to copy a file and change
three fields (finding B5). v3.15 ships it as a real manifest.

**And it makes drift invisible without a dedicated check.** v3.15 adds `SYNC_MODE=verify` for
exactly this: a `--dry-run` comparison that reports a drift count and exits nonzero when drift
exceeds a threshold, so the Job shows `Failed` in `kubectl get jobs` instead of the divergence
going unnoticed. Tier 1 (`meta`) catches everything above except mtime-preserved content changes;
Tier 2 (`checksum`) catches those too, on a rotating slice of the tree so the cost is spread.

---

## 3. Findings

Severity: **S1** = silent data loss or divergence; **S2** = job failures or operational blindness;
**S3** = documentation integrity.

### A1 — `CLIENT_ID` never reaches the sync in Deployment mode (S1)

**Where:** v3.14 §8.7 `entrypoint-deployment.sh`, §10B.1 `deployment-client.yaml`, §8.4 `nas-sync-incremental.sh`

`entrypoint-deployment.sh` exports the pod environment into `/etc/environment` for cron to source,
filtered by an allow-list:

```
printenv | grep -E '^(REMOTE_|LOCAL_|SYNC_|RSYNC_|EXCLUDE_|CHECK_|TZ|PARALLEL_|MANIFEST_)' > /etc/environment
```

`CLIENT_ID` matches no prefix in that list. Separately, `deployment-client.yaml` never sets
`CLIENT_ID` at all — v3.14 added the variable to the CronJob manifest and to the incremental
script but not to the Deployment manifest.

**Failure scenario:** deploy the Deployment with `SYNC_MODE=incremental`. `nas-sync-incremental.sh`
sees an empty `CLIENT_ID`, takes the legacy branch, and requests
`.nas-sync-state/sync-manifest.txt` — a path that does not exist under v3.14's per-client layout.
The fetch fails, the script logs `Manifest fetch failed — FULL sync fallback`, and runs a **full
tree sync**. This repeats every cycle, forever. The sync is not wrong, but it is orders of
magnitude more expensive than intended and the log line that explains it scrolls past unread.

**Fix in v3.15:** add `CLIENT_ID` to the allow-list regex, and add the `CLIENT_ID` env var to
`deployment-client.yaml`.

### A2 — A failed manifest fetch can silently reuse the previous run's manifest (S1)

**Where:** v3.14 §8.4 `nas-sync-incremental.sh`

```
MANIFEST_LOCAL="/tmp/sync-manifest.txt"
...
rsync -a --password-file="$RSYNC_PASSWORD_FILE" "${REMOTE_URL}/${MANIFEST_NAME}" "$MANIFEST_LOCAL" 2>&1
if [ ! -f "$MANIFEST_LOCAL" ]; then
```

The fetch's exit status is discarded, and the only check is whether the file exists.

**Failure scenario:** in a Deployment pod (long-lived, `/tmp` persists across cron runs), run N
fetches its manifest successfully. Run N+1's fetch fails — the generator was mid-write, the
gateway blipped, the daemon restarted. The stale file from run N is still at
`/tmp/sync-manifest.txt`, so `[ ! -f … ]` is false, the fallback never fires, and the client
re-transfers run N's already-synced change list. Everything that changed during window N+1 is
**silently skipped** until the weekly reconcile. The log shows a normal, successful incremental
sync.

In a CronJob pod `/tmp` starts empty, so the bug is latent there — but Deployment mode is a
documented, supported configuration.

**Fix in v3.15:** `rm -f "$MANIFEST_LOCAL"` before the fetch, capture the fetch's exit status, and
treat a nonzero status as a fetch failure regardless of what is on disk.

### A3 — Renames and moves are invisible, and leave duplicates behind (S1)

**Where:** inherent to v3.14 §4.3 `generate-manifests.sh`

Covered in detail in §2 above. Called out separately because it is the most likely real-world
divergence at this scale and because its second-order effect is easy to miss: with `--delete`
correctly banned, a moved file leaves a **stale copy at the old path** that no sync mode will ever
remove. Over months of reorganisation the target accumulates orphans. That is the accepted cost of
the no-delete policy, but it must be a known and documented cost.

**Fix in v3.15:** documented explicitly in the guide and in this review; the weekly reconcile is
promoted to a shipped artifact (B5); `SYNC_MODE=verify` makes the resulting drift measurable.

### A4 — The manifest lists regular files only (S1)

**Where:** v3.14 §4.3, `find … -type f -printf '%T@ %P\n'`

New empty directories, symlinks, and directory metadata changes never appear in a manifest and so
never propagate in `incremental` mode.

**Fix in v3.15:** `-type l` added alongside `-type f` so symlinks are carried; the empty-directory
and directory-metadata limits are documented inline in §4.3 and in §2 above, with the reconcile as
the repair path.

### A5 — Snapshot directories are pruned only at the root (S1/S2)

**Where:** v3.14 §4.3

```
find "$SOURCE_PATH" \
    -path "$SOURCE_PATH/.snapshot" -prune -o \
    -path "$STATE_DIR" -prune -o \
    -type f -printf '%T@ %P\n'
```

`-path "$SOURCE_PATH/.snapshot"` matches exactly one directory: the one at the top of the export.
NetApp exposes `.snapshot` inside **every** directory; Synology uses `@eaDir` similarly; ZFS-backed
exports use `.zfs/snapshot`.

**Failure scenario:** on a NetApp-style export with 7.4M folders, the walk descends into a snapshot
directory at every level. Walk time and manifest size inflate by the number of retained snapshots,
and the manifest lists paths that are point-in-time copies rather than live data. The rsyncd
`exclude =` in §5.2 stops most of it from actually transferring, so the symptom is a slow generator
and a bloated manifest rather than wrong data — but at this scale that is enough to make the
generator miss its window.

**Fix in v3.15:** switch to name-based pruning at all depths for `.snapshot`, `.snapshots`, `.zfs`
and `@eaDir`, keeping the existing path-based prune for the state directory.

### A6 — `--partial` without `--partial-dir` exposes truncated files on the target (S1)

**Where:** v3.14 §8.2, §8.3, §8.4 `RSYNC_FLAGS`; §9A.1 exclude ConfigMap

All three mode scripts pass `--partial`. Without `--partial-dir`, rsync keeps the partially
transferred data **at the destination filename**. The exclude ConfigMap already lists
`.rsync-partial/` — the intent was there, but no script ever set the flag that would use it.

**Failure scenario:** a sync is interrupted — `activeDeadlineSeconds` expires, the node is drained,
the gateway drops the connection mid-file. Truncated files are left at their real names on NAS A,
where whatever reads the target sees them as complete-but-corrupt. A subsequent run will fix them
(size mismatch triggers retransfer), but the window between is unbounded and silent.

**Fix in v3.15:** `--partial-dir=.rsync-partial` on every mode script, which makes the already-present
exclude entry meaningful.

### B1 — No Istio proxy-start gate; jobs fail on a cold start (S2)

**Where:** absent from the entire v3.14 guide; interacts with §8.2/§8.3/§8.4 preflight and §9A.2/§10B.1

Every mode script's first network action is:

```
nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null || die "Remote not reachable"
```

In an injected pod, the application container and `istio-proxy` start concurrently. Until the proxy
has received its configuration, outbound traffic is not routable. Nothing in the guide sets
`holdApplicationUntilProxyStarts`, and the script has no retry.

**Failure scenario:** a Job lands on a cold node, or during control-plane churn, or simply loses the
race. `nc` fails, the script dies immediately, the Job fails, `backoffLimit: 2` retries the whole
sync twice, and the operator sees "Remote not reachable" for a remote that is perfectly healthy.
This is the single most common Istio-plus-Job failure mode and the guide does not mention it.

**Fix in v3.15:** the annotation
`proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'` on both client pod templates,
plus a bounded retry loop around the preflight for clusters whose policy forbids the annotation.
Belt and braces, because the two fixes cover different causes.

### B2 — rsync exit 24 is treated as failure (S2)

**Where:** v3.14 §8.2–§8.4, `exit $SYNC_EXIT`; §9A.2 `backoffLimit: 2`

rsync returns 24 for "some files vanished before they could be transferred" and 23 for "partial
transfer due to error". On a live 7.4M-file source with an active application writing to it, 24 is
the **normal** outcome, not an error.

**Failure scenario:** a perfectly healthy sync copies everything it needed to and returns 24. The
Job reports `Failed`. `backoffLimit: 2` re-runs the entire sync twice, tripling load. The operator
learns that failures are routine and stops reading them — which is exactly the condition under
which a real failure gets missed.

**Fix in v3.15:** a shared `rsync_rc_ok()` helper that maps 0, 23 and 24 to success while logging a
warning naming the code, used by every mode script.

### B3 — Deployment cron has no overlap guard (S2)

**Where:** v3.14 §8.7

`concurrencyPolicy: Forbid` protects the CronJob path. The Deployment path runs its own internal
cron with no equivalent.

**Failure scenario:** `CRON_SCHEDULE` is every 2h and a reconcile takes 5h. At hour 2 a second rsync
starts against the same target while the first is still writing. Two rsync processes writing the
same destination tree race on temp files and directory creation, and NAS A takes double the write
load.

**Fix in v3.15:** wrap the cron command in `flock -n /var/lock/nas-sync.lock`, so an overlapping run
exits immediately with a logged message.

### B4 — Cron is registered twice in Deployment mode (S2)

**Where:** v3.14 §8.7

```
cat > /etc/cron.d/nas-sync << EOF
${CRON_SCHEDULE} root . /etc/environment && /userapp/scripts/dispatch-sync.sh > ...
EOF
chmod 0644 /etc/cron.d/nas-sync
crontab /etc/cron.d/nas-sync
```

`/etc/cron.d/` entries carry a user field; user crontabs must not. The same file is installed as
both. `cron -f` then reads both, and the user-crontab copy parses `root` as the command name.

**Failure scenario:** every scheduled tick produces one correct run plus one failed invocation
logging `root: command not found`. Harmless in effect, corrosive in practice — it trains the
operator to ignore errors in the sync pod's log.

**Fix in v3.15:** drop the `crontab` line. Writing `/etc/cron.d/nas-sync` is sufficient and is the
correct mechanism for the file format used.

### B5 — The weekly reconcile is not a shippable artifact (S2)

**Where:** v3.14 §12; absent from §14

Findings A3, A4 and A5 all have the same repair path: the weekly `parallel` reconcile. In v3.14 it
exists only as:

```
# Weekly full reconcile — copy cronjob-client.yaml, rename, change:
#   metadata.name: nas-sync-reconcile
#   schedule: "0 2 * * 0"
#   SYNC_MODE: parallel
```

It is not in the File Checklist and there is nothing to `kubectl apply`.

**Failure scenario:** the reconcile is the compensating control for every silent-miss class in this
design, and it is the one thing an operator working through the checklist will not deploy — because
it is not on the checklist.

**Fix in v3.15:** ship `cluster-a/cronjob-reconcile.yaml` as a real manifest in a new §9A.4, list it
in §14, and state in §12 that it is required rather than recommended.

### B6 — No run-status visibility (S2)

**Where:** v3.14 has no equivalent

The only evidence a sync ran is the pod log, and `successfulJobsHistoryLimit: 3` ages those out
within six hours on a 2h schedule. There is no way to answer "did last night's sync succeed?"
without having been watching.

**Fix in v3.15:** `dispatch-sync.sh` becomes a thin wrapper that writes `.nas-sync-status/last-run`
and `.nas-sync-status/last-success` onto the **target** NAS after every run — timestamp, mode, exit
code, duration, pod name. Written by the dispatcher, so all modes get it without duplication;
per-target by construction, since each target has its own NAS. Atomic `mv`; a write failure logs a
warning and never fails the sync. Any external monitor can poll the file later without this design
taking a Prometheus dependency.

### C1 — `CLAUDE.md` is stale (S3)

It names v3.13 "the authoritative v3.13 reference", its file table lists only v3.13, and its design
notes describe the superseded single marker-based `generate-manifest.sh` with `find -newer`. v3.14
replaced all of that. An agent or engineer following `CLAUDE.md` would edit the wrong file using
the wrong mental model.

**Fix in v3.15:** `CLAUDE.md` rewritten for v3.15 — corrected file table, the lookback-registry
model described accurately, `CLIENT_ID` documented as the third axis, and pointers to the runbook
and this review.

### C2 — The guide contradicts itself about source writability (S3)

v3.14 line 13 states the multi-target design means "no markers, source stays read-only". §5.4 and
§6.1 both require `readOnly: false` on the source NFS volume, because the generator writes manifests
into `.nas-sync-state/` on the source NAS. The correct statement is "no markers" — writability is
still required for `incremental`.

**Fix in v3.15:** corrected in the intro and cross-checked against §5.4, §6.1 and the new §S14
read-only-source scenario in the runbook.

### C3 — The v3.15 spec and plan are unexecutable as written (S3)

Both target `cross-cluster-rsync-guide-v3.13-consolidated.md` and assume v3.13's marker-based state.
Their Addition 4 proposes a `SYNC_ID` per-target marker layout to solve multi-target isolation — a
problem v3.14 had already solved differently with the client registry. Task 0 of the plan also
mis-identifies which guide file holds the pending edit.

**Fix in v3.15:** Additions 1–3 delivered rebased onto v3.14; Addition 4 dropped as superseded (§5
below). Both documents get a header note recording this. They are kept, not deleted — they hold the
alternatives research that §1 of this review cites.

### C4 — Opinionated excludes discard real source data without warning (S3)

**Where:** v3.14 §9A.1 exclude ConfigMap

The list drops `*.tmp`, `*.bak`, `.git/`, `System Volume Information/` and others. For a
general-purpose backup these are sensible. For a **replication** target where the goal is that
NAS A holds what NAS B holds, they silently discard real source data, and the resulting differences
will show up as drift in a verify run with no explanation.

**Fix in v3.15:** the exclude list is annotated in place explaining that each entry is a deliberate
choice, and noting that anything excluded here will also register as drift in `SYNC_MODE=verify`
unless excluded there too.

---

## 4. Summary table

| # | Severity | Finding | Status in v3.15 |
|---|---|---|---|
| A1 | S1 | `CLIENT_ID` missing from Deployment env → permanent full sync | Fixed |
| A2 | S1 | Stale manifest reuse skips a change window | Fixed |
| A3 | S1 | Renames invisible; leave duplicates | Documented; reconcile shipped; verify added |
| A4 | S1 | Manifest lists regular files only | Symlinks added; limits documented |
| A5 | S1/S2 | `.snapshot` pruned at root only | Fixed |
| A6 | S1 | `--partial` exposes truncated files | Fixed |
| B1 | S2 | No Istio proxy-start gate | Fixed |
| B2 | S2 | rsync exit 24 counted as failure | Fixed |
| B3 | S2 | Deployment cron has no overlap guard | Fixed |
| B4 | S2 | Cron registered twice | Fixed |
| B5 | S2 | Reconcile not a shippable artifact | Shipped as §9A.4 |
| B6 | S2 | No run-status visibility | Status file added |
| C1 | S3 | `CLAUDE.md` stale | Rewritten |
| C2 | S3 | Read-only-source contradiction | Corrected |
| C3 | S3 | v3.15 spec/plan unexecutable | Superseded, annotated |
| C4 | S3 | Excludes discard real data silently | Annotated |

---

## 5. Why Addition 4 (`SYNC_ID`) was dropped

The v3.15 spec proposed restructuring source-side state as
`.nas-sync-state/targets/<SYNC_ID>/{marker,sync-manifest.txt}` with one manifest CronJob per target,
each holding its own `find -newer` marker.

v3.14 solves the same problem — per-target isolation, so one target missing a cycle cannot advance
state on behalf of another — using a stateless lookback window instead:

| | v3.15 spec (`SYNC_ID` markers) | v3.14 (lookback registry) |
|---|---|---|
| Source write state | One marker file per target | None — only the manifest output |
| `find` walks per cycle | One **per target** | **One total**, fanned out by awk |
| CronJobs on Cluster B | One per target | One, driven by a registry ConfigMap |
| Adding a target | New CronJob manifest | One line in `clients.txt` |
| Recovery from a missed cycle | Marker advances anyway; changes lost until reconcile | Overlapping window absorbs it, up to `lookback_hours` |
| Failure mode if state is lost | Full sync | None — nothing to lose |

The lookback model wins on every axis that matters at this scale, and its recovery behaviour is
strictly better: a target that misses one cycle catches up automatically on the next, as long as the
outage is shorter than its configured lookback. The marker model has no such margin — it always
loses a missed cycle until the reconcile.

**Residual limitation, honestly stated:** an outage **longer** than `lookback_hours` still loses
those changes until the weekly reconcile repairs them. This is the same at-least-once-with-a-window
semantic the marker design has, just with a tunable margin. Set `lookback_hours` to the pull period
times 2–3, or to the pull period plus the worst outage you intend to tolerate. Runbook scenario S8
covers the recovery procedure.

Additions 1–3 from the spec — verify mode, chunked parallel reconcile, sync status file — are
orthogonal to the state layout and are carried forward unchanged in intent. The chunk directory
lands at `.nas-sync-state/common/chunks/`, which is exactly where the spec put it: chunks are a pure
split of the source tree and are valid for every target, so one weekly walk serves all of them.

---

## 6. Residual risks after v3.15

These are accepted, not fixed. They are properties of the constraints.

| Risk | Mitigation in place | What would remove it |
|---|---|---|
| Content changed with mtime preserved | `SYNC_MODE=verify` with `VERIFY_MODE=checksum`, rotating slice | Nothing cheaper exists without snapshot access |
| Orphan files at old paths after a rename | None — `--delete` is banned by policy | A periodic reconciliation report (not deletion) could list them |
| Outage longer than `lookback_hours` | Weekly reconcile; status file makes the outage visible | Raise `lookback_hours`; the cost is a larger manifest |
| Cleartext rsyncd across the site link | Accepted — link is trusted per constraints | TLS at the gateway, or stunnel, if policy changes |
| Source NAS load from the weekly full walk | Chunk generation replaced client-side `--list-only` discovery over the wire, moving the walk to the cheapest side | Snapshot-diff access on NAS B |
| N targets' reconciles colliding | Runbook S5 requires staggering schedules | Central scheduling |

---

## 7. References

- `cross-cluster-rsync-guide-v3.15-consolidated.md` — the corrected and hardened guide
- `docs/nas-sync-operations-runbook.md` — scenario-driven operator procedures
- `docs/superpowers/specs/2026-07-05-rsync-hardening-v315-design.md` — alternatives research (§3), cited in §1
- `scripts/check-guide.sh` — the consistency harness that verifies the guide's fenced blocks
