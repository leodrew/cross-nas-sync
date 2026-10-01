# v3.16 Design — Fixes for the 2026-10 Review Comments

**Date:** 2026-10-01
**Status:** Approved design — next step is the implementation plan
**Target:** new `cross-cluster-rsync-guide-v3.16-consolidated.md`, built from v3.15. v3.15 is frozen as history.

## 1. Background

Four review comments were raised against the v3.15 scripts. Each claim was reproduced against the
guide's own fenced scripts, extracted verbatim and run against:

- a local rsync 3.2.7 daemon (the version in `ubuntu:24.04`) configured like §5.2;
- `tini` as **PID 1 of its own PID namespace** (`unshare --pid --fork --mount-proc`), which is what a
  container is. An early test that skipped this step gave the wrong answer for comment 2 (§2, F6);
- Debian `cron` for the Deployment path.

| # | Comment (summary) | Verdict |
|---|---|---|
| 1 | §8.3 top-level split: awk does not drop `..`; `$NF` truncates names with spaces | `..`: **not a defect** — rsync never lists it. `$NF`: **confirmed, and wider than stated** (F3, F4) |
| 2 | `dispatch-sync.sh` does not forward SIGTERM, so mode-script cleanup traps never run | **Conclusion confirmed; mechanism differs.** `tini -g` does deliver SIGTERM to every process, but the parent chain dies instantly, PID 1 exits, and the kernel SIGKILLs rsync (F6, F7) |
| 3 | §4.6 chunk swap has a window where `CHUNK_DIR` does not exist | **Confirmed, and worse than stated.** The window itself is harmless; the real defect is a silently mixed chunk set (F1) |
| 4 | Manifest and chunk CronJobs share `$STATE_DIR` with no lock | **The cross-job case is safe** (disjoint write sets, tested). **The same-job case is broken** — `concurrencyPolicy: Forbid` is not a lock (F2) |

## 2. Findings

Severity: **H** = silently wrong result · **M** = wrong or slow, but visible · **L** = latent or cost-only.

| ID | Sev | Where | Defect | Evidence |
|---|---|---|---|---|
| F1 | H | §4.6, §8.3 | A chunk fetch that overlaps the swap gets a **mix of old and new generations with rc=0**. The rsync sender re-resolves each file by path, so files sent after the swap come from the new directory under the same names. | Swap at 0.3 / 1.5 / 3.0 s into a fetch: rc=0 every time, with 2/22, 8/16 and 16/8 old/new chunks. Simulation, 8 old + 16 new: **22.4 %** of the tree is in no fetched chunk, including 137 of 400 new or renamed paths — exactly what the reconcile exists to repair. |
| F2 | H | §4.3, §4.6 | Two runs of the **same** job overlap. The runbook itself triggers this with `kubectl create job --from=cronjob/…` (S1, S2, S4, S9; guide §11), which bypasses `concurrencyPolicy`. Job pod replacement and node partitions can also produce a second pod. | Manifest: torn paths in the published file (`158/f85`, `dd194/f47`), duplicate lines, the second run's awk still appending to the already-published file, and `file_count=0` meta. Chunks: run 2's `rm -rf $TMP_DIR` deletes run 1's work, and run 1 publishes run 2's half-written directory with `total_files=11778` (actual 20000). |
| F3 | H | §8.10 | verify tier 2 builds its slice from the same awk and discards rsync stderr and rc, so it is blind to folders with spaces, CJK or glob characters in their names. | Same-size, same-mtime corruption in `資料/` and `My folder/`: verify reports `drift=0 … VERIFY OK`; a checksum dry-run finds 2. |
| F4 | H\* | §8.3 | Top-level folder names are wrong in five ways. (a) `$NF` truncates at the last space. (b) The container has no `LANG`, so `--list-only` escapes non-ASCII as `\#ooo` (`資料` → `\#350\#263…`). (c) GNU xargs aborts on a `'` (`unmatched single quote`) and stops dispatching the rest. (d) **The daemon glob-expands remote paths**: `a[1]/` serves `a1`, `star*/` serves `starX`, so the wrong folder is written into the target. (e) `.nas-sync-state/` is listed and copied to every target, because excludes do not apply to a transfer root. Wrong paths return rc 23, which `rsync_rc_ok` accepts. | All reproduced. (d) overwrote `a[1]/f.txt` with `a1/f.txt` content. (e) copied 25 state files. \*Today masked by F5; it becomes silent data loss as soon as F5 alone is fixed. |
| F5 | M | §8.3 | The "loose files" pass is `rsync $RSYNC_FLAGS --dirs`, but `RSYNC_FLAGS` contains `-a`, which implies `-r`. The pass is therefore a **full serial sync of the whole tree** before the parallel workers start, and its rc is lost in `| grep`. | Running that single command copied every file. With `--no-recursive --dirs`, only the top level was copied. |
| F6 | M | §8.5, §8.6, §8.7 | No graceful shutdown on any path. The wrapper or entrypoint (tini's child) has no trap and dies at once; tini (PID 1) exits; the kernel SIGKILLs rsync mid-transfer. Runs launched by cron sit in their own session, which `tini -g` never reaches. | PID-namespace matrix, v3.15: an orphan `.blob.bin.XXXXXX` temp file is left in the target tree (never removed — there is no `--delete`), the mode-script trap never runs, and the work dir is left behind, for CronJob × {`-g`, no `-g`} × {standard, parallel} and for Deployment × {initial sync, cron run}. |
| F7 | M | §8.5 | Interrupted runs leave no record. `last-run` keeps showing the previous run. | In the same matrix, the status file is never written. |
| F8 | L | §6.1, §6.3 | Walks from the two different jobs overlap on Sundays (chunks at 00:00, manifests at `:50`), which doubles NAS metadata load. | Outputs are byte-identical to solo runs, so there is no correctness issue. |
| — | — | §8.3 | `..` in the folder list | rsync never lists `..`; only `.` (the transfer root) appears. Not a defect. |

## 3. Constraints

- **Rolling upgrade (runbook S11):** the source side is upgraded first, then one target, then the rest. A v3.16
  server must keep serving v3.15 clients. Rollback stays a tag change with no state migration.
- **Guide conventions (CLAUDE.md):**
  - never `--delete`;
  - never renumber sections;
  - a new script means four edits (its section, `COPY`, the `dos2unix`/CRLF lists, §14);
  - every block stays copy-paste-ready, with LF line endings and `◄ MODIFY` placeholders intact;
  - `bash scripts/check-guide.sh` passes.
- **rsync 3.2.7 behavior this design relies on (each item tested):**
  - `--exclude-from` filters `--list-only` output.
  - `--files-from` names are **not** glob-expanded.
  - Names listed explicitly in `--files-from` **bypass** excludes.
  - `-8` stops the escaping of high-bit bytes but still escapes control characters as `\#ooo`.
  - rsync installs its own SIGTERM handler even when it inherits `SIG_IGN`.
  - A second SIGTERM does not stop rsync from saving its partial file.
  - The sender re-resolves file paths while sending (the cause of F1).

## 4. Design A — Cluster B publishing and locking (F1, F2, F8)

### 4.1 Chunk generations (§4.6 server, §8.3 client)

**Server side**
- Each run sets `GEN="g${NOW}"`.
- `split` writes `chunk-${GEN}-NNN.txt`. `split -n r/N` always creates N files, including empty ones.
- `chunks.meta` gains a `generation=${GEN}` line. It is still written last, inside the temp directory.
- The swap block itself is unchanged; only its comment is corrected. A fetch that overlaps the swap now
  asks for names that no longer exist and gets **rc 24 ("vanished")**, never a mix. This was tested: rc=24
  at all three swap points.
- v3.15 clients already treat rc≠0 as "fall back", so they are protected **without being upgraded**.
- v3.15's `ls chunk-*.txt` still matches the new names.

**Client side (§8.3)** accepts a fetched set only if all of the following hold:
1. the fetch returned rc 0;
2. `chunks.meta` is present and fresh (unchanged from v3.15);
3. `generation` is non-empty;
4. the count of `chunk-${GEN}-*.txt` equals `chunk_count`;
5. the count of all `chunk-*.txt` equals that same number.

On rc 24 or a failed check:
- log the reason;
- wait `CHUNK_RETRY_WAIT` (new env, default `30`);
- empty the local chunk dir and fetch once more;
- if it fails again, fall back to the top-level split.

A stale set falls back immediately, as in v3.15.

A `chunks.meta` with no `generation` line comes from a v3.15 server, which only happens after a rollback. In that
case the client logs a WARN and accepts `chunk-*.txt`, which is v3.15 behavior.

Workers consume only `chunk-${GEN}-*.txt`.

### 4.2 Lock library — new §4.7 `cluster-b/scripts/nas-sync-state-lock.sh`

Sourced by §4.3 and §4.6. Each job has its own lock: `manifests` and `chunks`. There is no lock *between* the two jobs
(F8, §4.4).

**Layout.** `$STATE_DIR/locks/<name>.lock/` is a directory containing two files:
- `owner`: `run_id`, host, pid, and start epoch;
- `heartbeat`: touched every `LOCK_HEARTBEAT` seconds.

**Tunables:**
- `LOCK_HEARTBEAT`, default `60`;
- `LOCK_STALE`, default `600`.

**`lock_acquire <name>`**
1. `mkdir -p $STATE_DIR/locks`, then `mkdir <name>.lock`. `mkdir` is atomic on every NFS version; `flock`
   was rejected because a `nolock` mount silently makes it node-local.
2. **On success:**
   - write `owner`;
   - touch `heartbeat`;
   - start the heartbeat loop in the background;
   - register `lock_release` on EXIT;
   - return 0.
3. **On failure, measure the age of the existing lock.** Use a NAS-stamped clock: touch a probe file
   `locks/.probe.<run_id>`, take its mtime as "now", then remove it. Pod clocks are never compared with NAS
   mtimes.
   - **Age ≤ `LOCK_STALE`:** log `lock '<name>' held by <owner> (heartbeat <age>s ago) — another run is in
     progress; this run did nothing`, then **`exit 75`**. The Job shows Failed, which accurately says the run did
     not happen. The runbook tells the operator to re-run after the holder finishes.
   - **Age > `LOCK_STALE`:**
     1. log a WARN;
     2. `mv <name>.lock <name>.lock.stale.<run_id>`. Rename is atomic, so exactly one contender wins. A failed
        `mv` means someone else won: exit 75.
     3. `rm -rf` the renamed directory;
     4. `mkdir` once more. If that fails, exit 75.

**`lock_release`**
- stop the heartbeat loop;
- remove the lock directory **only if** `owner` still carries our `run_id`.

**Why a heartbeat instead of a fixed TTL.** A walk may legitimately run for up to `activeDeadlineSeconds`
(24 h). A TTL long enough to cover that would let one crashed run block the 2-hourly manifest job for a
day. A SIGKILLed or deadline-killed run stops heartbeating, and its lock expires 10 minutes later.

### 4.3 Per-run names and atomic meta (defense in depth)

Every run sets `RUN_ID="$(hostname)-$$-${NOW}"`. `$$` alone collides across containers.

| Before (v3.15) | After (v3.16) |
|---|---|
| `sync-manifest.txt.tmp` | `sync-manifest.txt.tmp.${RUN_ID}` |
| `.chunks.tmp` / `.chunks.old` | `.chunks.tmp.${RUN_ID}` / `.chunks.old.${RUN_ID}` |
| `printf … > manifest.meta` | write `manifest.meta.tmp.${RUN_ID}`, then `mv -f` |

Leftovers from crashed runs are removed only **while holding the lock**:
- `sync-manifest.txt.tmp*`
- `.chunks.tmp*`
- `.chunks.old*`

These globs also cover the unsuffixed v3.15 names.

Even if a lock were wrongly broken, the two runs could no longer write into each other's files.

### 4.4 Cross-job overlap (F8)

The two jobs get no shared lock. It would make the 2-hourly manifest wait behind a multi-hour chunk walk,
and their write sets are disjoint.

§6.3 gains a note about the Sunday load overlap, and suggests moving the chunk schedule if NAS metadata load
becomes a problem.

## 5. Design B — Top-level folder names on the client (F3, F4, F5)

### 5.1 New §8.11 `cluster-a/scripts/nas-sync-lib.sh`

This is a shared library, sourced by every client script. It holds **only new functions** (`list_top_dirs`, `wait_child`,
`term_trap_install`, `check_term`). Existing duplicated functions such as `rsync_rc_ok` and `wait_for_remote`
stay where they are, because moving them is unrelated refactoring.

**`list_top_dirs`** writes NUL-terminated top-level directory names to stdout and returns rsync's rc.
1. List:
   `rsync --list-only -8 --password-file=… ${EXCLUDE_FILE:+--exclude-from="$EXCLUDE_FILE"} "${REMOTE_URL}/"`.
   Applying the client exclude file here drops `.nas-sync-state`, `.git`, and similar names with the same semantics
   as the sync itself (F4e).
2. Keep only lines matching
   `^d[^ ]* +[0-9,.]+ [0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (.*)$`, using `sed` under `LC_ALL=C`.
   - The name is everything after the timestamp, so spaces, leading spaces and tabs survive.
   - `LC_ALL=C` parses bytes, not characters, so a name that is not valid UTF-8 (legacy Big5/MS950) survives
     whatever `LANG` the image sets. A `grep -vx '\.'` stage here silently dropped such names under a UTF-8
     locale (`binary file matches` on stderr, exit 0), so that folder was never synced; there is no `grep` stage.
   - Daemon MOTD lines never match.
   - Top-level symlinks are left to the loose-files pass, as in v3.15.
3. Drop the `.` entry and decode only `\#ooo` sequences, in one `perl` stage:
   `perl -ne 'chomp; next if $_ eq "."; s/\\#([0-7]{3})/chr(oct($1))/ge; print "$_\0"'`.
   - bash `printf %b` is unsafe here, because it would also turn a literal `\n` inside a name into a newline.
   - `perl` comes from `perl-base`, which is Essential in `ubuntu:24.04`.
   - §8.8's tool check gains `command -v perl`.

### 5.2 `nas-sync-parallel.sh` (§8.3)

**Loose-files pass**
- `rsync $RSYNC_FLAGS --no-recursive --dirs …` (F5).
- Its rc is captured through `PIPESTATUS` and recorded as a unit named `loose`.

**Workers**
- `list_top_dirs` output becomes NUL-separated `index, name` pairs.
- These are dispatched with `xargs -0 -n 2 -P "$PARALLEL_WORKERS"`, run in the **background** as
  `( trap '' TERM; exec xargs … ) < "$FOLDER_LIST" &` and collected with `wait_child $!` (`XARGS_RC=$WAIT_RC`).
  A foreground xargs would defer the SIGTERM trap until xargs had exited, by which time it had started every
  remaining unit. The chunk path writes its sorted NUL list to a file first and redirects xargs's stdin from it,
  so `$!` is xargs itself.
- **Stop file.** `STOP_FILE="$WORK_DIR/stop"` is exported. The SIGTERM trap (§8.11 `term_trap_install`) creates it
  when `STOP_FILE` is set. The first thing `sync_one_chunk` and `sync_one_folder` do is check for it: if it exists,
  they log a `SKIP` line, write rc `143` to the unit's rc file (so the rc-count invariant below still holds) and
  return 0 without starting rsync. Without it, a worker that finished returned 0 and xargs started the next unit
  after the one-shot group SIGTERM had passed, so queued units ran to completion. `WORK_DIR` is removed before
  use, so a stop file left by a killed run with the same PID cannot skip this run's units.
- Each worker runs
  `printf '%s\0' "$name" | rsync $RSYNC_FLAGS -r --from0 --files-from=- "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/"`.
  - The name is never part of a remote path, so it is never glob-expanded (F4d).
  - `-r` must be explicit, because `-a` does not imply it under `--files-from`.

**Bookkeeping**
- Each worker writes its rc to `rc/folder-<index>` and its name to `names/folder-<index>` (`NAME_DIR`, a separate
  directory, so `rc/` holds only rc files and the rc-count invariant below stays exact).
- The failure report prints names with `printf %q`.
- Log prefixes use the index, not the name, so the `sed "s/^/[$folder] /"` injection is gone.

**Invariants**
These apply to the chunk path and the folder path alike:
- xargs exit status must be 0;
- the number of rc files must equal the number of dispatched units.

Either failing is a run failure. This catches xargs stopping partway (F4c).

### 5.3 `nas-sync-verify.sh` tier 2 (§8.10)

- Slices come from `list_top_dirs`. The hash is `cksum` over the raw name bytes, so ordinary names stay in the
  same slice as in v3.15; only names v3.15 misparsed move.
- Each slice directory is compared with
  `printf '%s\0' "$d" | rsync $BASE_FLAGS --checksum -r --from0 --files-from=- "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/"`.
- stderr goes to a file instead of `/dev/null`.
- **rc handling:**
  - Any rc outside {0, 23, 24} fails the run, printing the first lines of stderr.
  - rc 23 is logged as a WARN with the first stderr line; it usually means the directory was removed between
    listing and checking.

## 6. Design C — Signals and status (F6, F7)

**Rule: one place signals; everyone else waits.** A shell that has children never exits before them. When the top
shell exits early, tini (PID 1) exits and the kernel SIGKILLs everything that is left.

**Shared helpers (§8.11)**

`wait_child <pid>` sets `WAIT_RC` to the child's real exit status, even when a trap interrupts `wait`:
```bash
wait_child() { local r; while :; do wait "$1"; r=$?; [ "$r" -le 128 ] && { WAIT_RC=$r; return; }
               kill -0 "$1" 2>/dev/null || { WAIT_RC=$r; return; }; done; }
```

**Each layer**

| Layer | Behavior on SIGTERM |
|---|---|
| §8.6 wrapper — top of the CronJob chain | 1. The trap guards against re-entry, then runs `kill -TERM 0` **once**, signalling its own process group, so delivery does not depend on `tini -g`. 2. The dispatcher runs in the background; the wrapper waits with `wait_child`. 3. When interrupted, it skips the sidecar quit (kubelet is already stopping `istio-proxy`) and exits with the dispatcher's code. |
| §8.5 dispatcher | 1. The mode script runs in the background. 2. The trap only records `GOT_TERM=1`. 3. `wait_child` collects the mode script's exit code. 4. If interrupted and the mode script still returned 0, `RC` becomes 143; the status line gains ` interrupted=TERM`, and `last-success` is **not** written. Status parsers that split on spaces and `=` are unaffected. **No `exec`** — the status write needs the dispatcher to outlive the mode script. |
| Mode scripts (§8.2, §8.3, §8.4, §8.10) | 1. `term_trap_install` sets `trap 'TERMINATING=1' TERM INT` (and, when `STOP_FILE` is set, creates that file). bash runs it only **after** the foreground rsync exits, which lets rsync move its partial file into `.rsync-partial/` first. 2. `check_term` runs after every rsync step and inside the `wait_for_remote` loop; when the flag is set it logs and does `exit 143`, never starting the next step. 3. In §8.3, xargs runs in the **background** as `( trap '' TERM; exec xargs … ) &`, collected with `wait_child $!`, so the trap fires at once and xargs keeps waiting for the in-flight workers while each rsync still handles TERM itself. The trap also creates `STOP_FILE`; each worker checks it first and, if it exists, logs `SKIP`, records rc 143 and does not start rsync. So running rsyncs stop and save their partials, queued units are skipped, and the script exits 143. |
| §8.7 entrypoint — Deployment | 1. **No `exec cron -f`.** bash stays tini's child for the pod's whole life. 2. The initial sync runs in the background under `flock`, collected with `wait_child`. 3. After that, `cron -f &` runs, followed by `wait_child "$CRON_PID"`. 4. On SIGTERM it stops cron, then sends TERM to **each in-flight run's process group**. The groups are found as the pgids of `/userapp/scripts/dispatch-sync.sh` processes, because cron gives each job its own session, which `tini -g` cannot reach. 5. It then drains: it polls until no run remains, for up to `SHUTDOWN_WAIT` (new, default `50`), then exits 143. 6. If cron exits unexpectedly, the entrypoint exits 1 so the pod restarts. |

**Grace period.** `terminationGracePeriodSeconds: 60` is set explicitly in §9A.2, §9A.4, §9A.5 and §10B.1.
- 60 s gives NFS room to flush dirty pages of a large in-flight file.
- `SHUTDOWN_WAIT` stays below it.

**`tini -g`** stays in §8.8 and §10B.1, with a comment that it is now belt-and-braces. Correctness no longer
depends on it, as the matrix below shows.

**Validated with prototypes** (tini as PID 1; "partial" means saved to `.rsync-partial/`):

| Path | v3.15 | v3.16 prototype |
|---|---|---|
| CronJob, `-g`, standard | orphan temp file, no trap, no status | partial saved, trap ran, `exit=143 interrupted=TERM` |
| CronJob, `-g`, parallel (2 workers) | 2 orphan temp files | 2 partials saved, same status |
| CronJob, **no** `-g`, standard / parallel | same failures | same success |
| Deployment, SIGTERM during initial sync | orphan temp file, no status | partial saved, `exit=143 interrupted=TERM` |
| Deployment, SIGTERM during a cron run | orphan temp file; status still shows the previous run | partial saved, `exit=143 interrupted=TERM` |

## 7. Error handling summary

| Situation | Behavior | Visible as |
|---|---|---|
| Chunk fetch overlaps a swap | rc 24 → wait 30 s → refetch once → fall back | log line, then a normal run |
| Generation mismatch or wrong count | same as above | log line |
| Lock held by a live run | `exit 75`, nothing written | Job Failed + `lock … held by …` |
| Stale lock (no heartbeat for 10 min) | broken atomically, run proceeds | WARN line |
| xargs aborted, or rc-file count ≠ units | run fails | `exit 1` + reason |
| verify rsync rc ∉ {0, 23, 24} | verify fails | `exit` with rc + first stderr lines |
| SIGTERM (any path) | rsync stops cleanly, partial kept, status written | `last-run … exit=143 interrupted=TERM` |
| Cron run still busy at `SHUTDOWN_WAIT` | WARN, then exit; kubelet SIGKILLs at the grace limit | WARN line |

## 8. Compatibility and rollout

| Combination | Result |
|---|---|
| v3.16 server + v3.15 clients (the normal mid-upgrade state) | Chunk names match `chunk-*.txt`. An overlapping fetch fails (rc 24) and falls back, which is safe. Manifests are unchanged. |
| v3.15 server + v3.16 clients (only after a rollback) | `chunks.meta` without `generation` is accepted with a WARN (v3.15 behavior). Everything else is unchanged. |
| Leftover v3.15 temp names on the NAS | Cleaned up by the v3.16 globs, under the lock. |
| `locks/` left behind after rolling back to v3.15 | Ignored by v3.15. It sits under `.nas-sync-state/`, so it is never replicated. |

**Upgrade step to add to the migration appendix:** before applying the v3.16 CronJobs on Cluster B, wait for
any in-flight `nas-sync-manifest` / `nas-sync-chunks` Job to finish (`kubectl get jobs -n ea-pmc`). A v3.15 run
takes no lock, so it could overlap the first v3.16 run.

## 9. Guide integration (bookkeeping)

- **New file:** `cross-cluster-rsync-guide-v3.16-consolidated.md`, a copy of v3.15 plus the changes below. Title
  and version labels become v3.16; image tags become `:3.16`.
- **New sections:** §4.7 (`nas-sync-state-lock.sh`) and §8.11 (`nas-sync-lib.sh`). Existing sections are never
  renumbered.
- **Four edits for each new script:**
  1. its section;
  2. `COPY` in §4.4 / §8.8;
  3. the `dos2unix` + CRLF-guard lists;
  4. §14.
- **Changed sections:**
  - §4.3, §4.4, §4.6, §6.1 (comment), §6.3 (note);
  - §8.2, §8.3, §8.4, §8.5, §8.6, §8.7, §8.8, §8.10;
  - §9A.2, §9A.4, §9A.5 and §10B.1 (grace period).
- **§13 Troubleshooting, three new entries:**
  - "Job failed with `lock … held` (exit 75)";
  - "Chunk fetch rc=24 / generation mismatch";
  - "Status shows `interrupted=TERM`".
- **§14:** add the two new files to the checklist, and add one v3.16 row per fix to What This Consolidates.
- **New appendix "Also required when coming from v3.15 → v3.16":**
  - upgrade order;
  - the in-flight-Job wait above;
  - no state migration;
  - the new `locks/` dir;
  - apply the grace periods;
  - rollback is a tag change.
- **Runbook:**
  - S1, S2, S4, S9: what to do when a manual run hits `lock held`. In S4, the running instance read the registry
    before the new line was added, so re-run after it finishes.
  - S5: reading `interrupted=TERM`.
  - S11: `3.16` tags and a link to the new appendix.
  - S12: add a lock-held branch to the triage tree.
- **CLAUDE.md:**
  - The file table makes v3.16 authoritative and v3.15 history.
  - "Non-Obvious Design Decisions" gains five bullets: one signals / all wait; generation-unique chunk names;
    `mkdir` locks on NFS; names via `--files-from --from0`; `--list-only` escaping and daemon glob expansion.
  - "Commands" gains the behavior test.

## 10. Testing

### 10.1 `scripts/check-guide.sh` — v3.16 regression block

This is a new `case *v3.1[6-9]*` block. The v3.15 block stays.

**Must be present:**
- `--from0`;
- `--no-recursive --dirs`;
- `generation=`;
- `lock_acquire` in both generator sections;
- `kill -TERM 0` in §8.6;
- `wait_child`;
- `terminationGracePeriodSeconds`;
- `list_top_dirs` in §8.10;
- `command -v perl`.

**Must be absent:**
- `$NF != "."`;
- `exec cron -f`;
- a bare `--dirs` not preceded by `--no-recursive`.

### 10.2 New `scripts/test-guide-behavior.sh [--slow] [--native] [guide.md]`

Static checks cannot see any of these defects; they appear only at runtime, with rsync, NFS-style renames,
signals and PID 1. The harness turns the reproductions behind this spec into a regression suite.

**How it runs**
- It extracts the scripts from the guide's fenced blocks, the same way `check-guide.sh` parses them.
- It installs them under `/userapp/scripts`.
- It starts an rsync daemon on a free port with a §5.2-style config, in a temp dir.
- **Default:** it runs inside `docker run --rm --privileged ubuntu:24.04` with the repo bind-mounted, so it
  works from Windows/MSYS and never touches the host.
- **`--native`:** runs on a Linux host as root, for CI or a sandbox.
- **Needs:** rsync, tini, perl, unshare; cron for `--slow`.
- A case is skipped with a WARN only when its tool is missing.

| Case | Asserts |
|---|---|
| `names` | Fallback parallel syncs folders named `My folder`, `資料`, `John's`, `a[1]`, `star*`, `" lead"`, a tab, a newline, `-n`, with byte-identical content (no glob cross-talk). `.nas-sync-state` is not copied. verify tier 2 detects same-size/same-mtime drift inside them. |
| `loose` | The loose-files pass copies only the top level. |
| `swap` | A fetch overlapping the §4.6 swap ends in either a consistent single-generation set or rc≠0 → retry/fallback. Never a mix. |
| `lock` | Overlapping manifest runs: the second exits 75, and the published manifest equals the solo baseline. Same for chunks. A lock whose heartbeat is older than `LOCK_STALE` is broken. |
| `signal` | With tini as PID 1, the 2×2 matrix ({`-g`, no `-g`} × {standard, parallel}) leaves no orphan `.<name>.XXXXXX` temp file, saves partials, and writes `interrupted=TERM`. |
| `deploy` (`--slow`, ~1 min) | The entrypoint shuts down cleanly during the initial sync and during a cron run. |

**Sanity check:** run against the v3.15 guide, **every case must fail**. `names` fails through glob cross-talk and the
`.nas-sync-state` leak, even though F5's full serial pass hides the missing data. This proves the harness detects the
defects; it is recorded in the implementation plan's verification step.

## 11. Out of scope

- verify's "N entries compared" counts only the itemized (differing) lines. The label is misleading but harmless.
- Moving the existing duplicated helpers (`rsync_rc_ok`, `wait_for_remote`) into the new library.
- Cluster B job pods run `/bin/bash` as PID 1 with no signal handling. A deadline kill leaves the lock behind; the
  heartbeat expiry (§4.2) is the designed recovery.
- A shared lock between the manifest and chunk jobs (§4.4).
- Tuning `CHUNK_COUNT` or `PARALLEL_WORKERS`.

---

## Appendix A — 給 reviewer 的回覆（可直接貼上）

> 以下結論皆以 v3.15 guide 原文 script 實測：本機 rsync 3.2.7 daemon（與 image 同版）、tini 以
> PID 1 執行於獨立 PID namespace（等同 container）、Debian cron。

**Comment 1 — `nas-sync-parallel.sh` top-level split**
- **`..`：不成立。** rsync 的 file list 不會出現 `..`，`--list-only` 只會列出 `.`（transfer root）。
- **`$NF` 截斷：成立，而且影響比描述的更廣。** 實測有五種錯誤：
  1. 名稱含空白會被截斷：`My folder` 變成 `folder`。
  2. container 沒有設定 `LANG`，非 ASCII 名稱會被跳脫成 `\#ooo`：`資料` 變成 `\#350\#263…`。
  3. 名稱含 `'` 時 xargs 會中止，剩下的資料夾全部不會派工。
  4. **daemon 會對遠端路徑做 glob 展開**：`a[1]/` 實際傳的是 `a1` 的內容，會寫進 target 的 `a[1]/`。
  5. `.nas-sync-state/` 會被複製到每個 target。
- 這些錯誤的 rc 都是 23，被 `rsync_rc_ok` 當成成功。
- 目前之所以沒有遺漏資料，是被另一個 bug 蓋住了：loose-files pass 的 `-a` 隱含 `-r`，實際上會先 serial 全量同步一次。只修那一個 bug，上面的問題就會變成無聲的資料遺漏。
- **今天就會出錯的地方：** verify tier 2 用的是同一行 awk。實測把 `資料/`、`My folder/` 裡的檔案改成同 size、同 mtime 但內容不同，verify 仍回報 `VERIFY OK`。
- **v3.16 修法：**
  - 用 `--list-only -8` 加上 exclude file 列出資料夾，固定欄位解析後只解碼 `\#ooo`，以 NUL 分隔輸出。
  - worker 改用 `--files-from --from0 -r` 傳送，名稱不會再被 glob 展開。
  - loose-files pass 改成 `--no-recursive --dirs`。
  - 檢查 xargs 的 rc，並確認 rc 檔數等於派工數。

**Comment 2 — dispatcher 不轉發 SIGTERM**
- **結論成立，但機制不同。** ENTRYPOINT 是 `tini -g`，SIGTERM 其實會送達整個 process group。真正的問題在於：
  1. wrapper（tini 的直接子行程）沒有 trap，收到 SIGTERM 會立刻結束。
  2. tini 身為 PID 1 隨之退出。
  3. kernel 對其餘行程送出 SIGKILL。
- 實測結果：
  - target 留下 `.檔名.XXXXXX` 暫存檔。因為不使用 `--delete`，這些檔案會一直留著。
  - mode script 的 trap 沒有執行。
  - status 沒有記錄這次中斷。
- 不論有沒有 `-g` 都會發生。Deployment 由 cron 啟動的 run 在自己的 session 裡，連 `-g` 都送不到。
- **`exec "$MODE_SCRIPT"` 不能用。** dispatcher 必須在 mode script 結束後寫入 status。
- **v3.16 修法：** 只由一個地方發送訊號，其餘全部等待。
  - wrapper 對 process group 送一次 TERM，然後等待子行程。
  - dispatcher 與 mode script 等 rsync 結束後才退出，status 記錄 `exit=143 interrupted=TERM`。
  - Deployment 的 entrypoint 不再 `exec cron`，改由 bash 監督，逐一通知 cron 啟動的 run 並等待它們結束。
  - 明確設定 grace period 為 60s。
  - 實測 rsync 能把 partial 存進 `.rsync-partial/`，有無 `-g` 都一樣。

**Comment 3 — chunk swap 空窗**
- **空窗本身無害。** 這段時間的 fetch 會失敗（rc≠0），然後走 fallback，與註解描述一致。
- **但「最壞只是失敗一次」是錯的。** rsync sender 傳每個檔案時會依路徑重新解析，swap 之後的同名檔案會改從新目錄讀取。實測 client 以 **rc=0** 收到新舊混合的 chunk set，例如 8 份舊、16 份新。
- 模擬結果：約 22% 的路徑不在任何一份 chunk 中，正好包含 reconcile 要補的新增與改名檔案。
- **v3.16 修法：**
  - 每一代 chunk 使用不同的檔名（`chunk-<gen>-NNN.txt`），meta 記錄 `generation`。實測交錯的 fetch 會得到 rc=24，而不是混合的 set。舊版 client 本來就會在 rc≠0 時 fallback，所以不升級也安全。
  - 新版 client 還會檢查 generation 與檔案數，不符時重試一次，再不行才 fallback。

**Comment 4 — 跨 cron job 沒有鎖**
- **兩個不同的 job 同時執行是安全的。** 兩者寫入的路徑沒有重疊，兩邊的 `find` 也都會略過 `$STATE_DIR`。實測同時執行的輸出與各自單獨執行逐檔一致，唯一的代價是 NAS 的 metadata 負載加倍。
- **真正的問題是同一個 job 執行兩份。** `concurrencyPolicy: Forbid` 只是排程規則，不是鎖：
  - runbook S1、S2、S4、S9 用的 `kubectl create job --from=cronjob/...` 會直接繞過它。
  - Job 替換 pod 或 node 失聯時，也可能同時存在兩個 pod。
- 實測結果：
  - manifest 出現被截斷的路徑與重複的行，meta 寫成 `file_count=0`。
  - chunk set 在寫到一半時就被發布，`total_files` 也是錯的。
- **v3.16 修法：**
  - 每個 job 各自用 NFS 上的 `mkdir` lock，搭配 heartbeat，10 分鐘沒有更新就視為過期。
  - 鎖被佔用時以 exit 75 結束，Job 會顯示 Failed，log 會寫出佔用者。
  - 每次執行使用獨立的 temp 檔名，meta 以 rename 方式原子寫入。
  - 不在本機用 `flock`：不同 pod 可能在不同 node 上；NFS 若以 `nolock` 掛載，`flock` 只在單一 node 內有效，而且不會有任何提示。
