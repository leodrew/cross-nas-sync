# Fast Daily Cross-Cluster NAS Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Edit the existing guide so the daily sync of ~6 TB / ~7.4 M files scales with the change rate (not dataset size), via a parallelized server manifest + a freshness-guarded `--files-from` client pull, backed by a weekly parallel reconcile.

**Architecture:** Three tracks on one image — `parallel` Deployment (initial, one-time), `incremental` daily CronJob (fast path, never walks the tree), `parallel` weekly reconcile CronJob (correctness backstop, ≤7-day convergence). The novel logic is the rewritten manifest generator (parallel `find`, conservative marker, atomic publish + `# COMPLETE` sentinel) and the rewritten incremental client (explicit manifest fetch, freshness guard, skip+alert, last-consumed tracking).

**Tech Stack:** Bash (Ubuntu 24.04 containers), GNU `find`/`xargs`, rsync daemon protocol, Kubernetes CronJob/Deployment, Istio. Edits are confined to one Markdown file plus `CLAUDE.md`.

---

## Scope & deliverable

This is a **documentation-only** change (chosen by the user). Everything lands as edits to:

- `cross-cluster-rsync-guide-v3.13-consolidated.md` (the guide)
- `CLAUDE.md` (pointer + contract note)

No standalone scripts, no test runner, no cluster calls. The guide remains the copy-paste source of truth.

**Reference spec:** `docs/superpowers/specs/2026-06-20-fast-daily-nas-sync-design.md` (read it before starting).

## File structure (what each edit owns)

| Section in guide | Responsibility | Task |
|---|---|---|
| Top blockquote (lines ~1–14) | Advertise the v3.14 contract (manifest path, sentinel, skip+alert, 3 tracks) | T2 |
| §4.3 `generate-manifest.sh` | **Rewrite** — parallel walk, conservative marker, atomic publish + sentinel, prune, `.sync-state/` path | T3 |
| §5.2 `configmap-rsyncd.yaml` | Add `.sync-state/` to module exclude | T4 |
| §6 manifest CronJob | Lead-time schedule, `STATE_SUBDIR`/`PARALLEL_WORKERS` env, confirm `readOnly:false` | T5 |
| §8.4 `nas-sync-incremental.sh` | **Rewrite** — explicit fetch, freshness guard, skip+alert, last-consumed | T6 |
| §9A.1 `configmap-exclude.yaml` | Add `.sync-state/` | T7 |
| §9A.2 `cronjob-client.yaml` | Daily `incremental`, `backoffLimit: 0` | T8 |
| §9A.3 `cronjob-reconcile.yaml` (NEW) | Weekly `parallel` reconcile | T9 |
| §12 Choosing Sync Mode | Rewrite to the three-track model + contract | T10 |
| §13 Troubleshooting | Stale-manifest skip, slow find, manifest-not-found | T11 |
| §14 File Checklist + Deploy Order | Add reconcile job + `.sync-state` notes | T12 |
| `CLAUDE.md` | Point to spec, note v3.14 contract | T13 |
| (whole file) | Consistency sweep + `bash -n` on both scripts | T14 |

**Convention used by every task:** edits are anchored by **section heading + the exact existing text to replace** (line numbers drift as you edit, so don't rely on them). Use the Edit tool with the shown `OLD` block as `old_string` and the shown `NEW` block as `new_string`.

---

## Task 1: Initialize git baseline (optional but recommended)

Enables the per-task commits below and gives you rollback on a heavily-edited single file. Skip this task (and every `git commit` step) if you don't want version control.

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Init repo**

Run:
```bash
git init
git config user.email "leotsmc1216@gmail.com"
git config user.name "leo01"
```
Expected: `Initialized empty Git repository ...`

- [ ] **Step 2: Add a .gitignore**

Create `.gitignore` with:
```gitignore
# local scratch
/tmp/
*.tmp
.DS_Store
Thumbs.db
```

- [ ] **Step 3: Baseline commit (current state, before edits)**

Run:
```bash
git add -A
git commit -m "chore: baseline before fast-daily-sync edits"
```
Expected: a commit containing the guide, CLAUDE.md, spec, and this plan.

---

## Task 2: Advertise the v3.14 contract in the top blockquote

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (top blockquote, §1 intro)

- [ ] **Step 1: Replace the version blockquote**

`OLD` (current top blockquote):
```markdown
> **This version consolidates everything:**
> - **CRLF-safe build** (dos2unix + build-time verification) — from v3.12
> - **Sidecar self-quit wrapper** (curl/wget/pilot-agent/bash fallbacks) — from v3.11
> - **Two speedup approaches** for 7.4M folders: parallel walk + incremental change-list
> - **Both k8s types** in the deployment YAMLs: CronJob AND Deployment, each able to run any sync mode
>
> **Port:** 8787 | **Delete:** Disabled | **Logging:** Console only | **Namespace:** ea-pmc
>
> **One image, selectable behavior** via `SYNC_MODE` env var:
> - `standard` — single rsync (original)
> - `parallel` — N concurrent workers split by top-level folder (faster walk)
> - `incremental` — sync only changed files via server manifest (skip full walk)
```

`NEW`:
```markdown
> **This version consolidates everything:**
> - **CRLF-safe build** (dos2unix + build-time verification) — from v3.12
> - **Sidecar self-quit wrapper** (curl/wget/pilot-agent/bash fallbacks) — from v3.11
> - **Two speedup approaches** for 7.4M folders: parallel walk + incremental change-list
> - **Both k8s types** in the deployment YAMLs: CronJob AND Deployment, each able to run any sync mode
>
> **v3.14 fast-daily contract:**
> - Manifest lives at `<source>/.sync-state/manifest.txt`, served via the `nas-data` module.
> - Manifest ends with a `# COMPLETE <epoch> <count>` sentinel; clients refuse any manifest without it.
> - Daily client = freshness-guarded `--files-from` pull (no tree walk); **stale/missing manifest → skip + alert** (never a silent full sync).
> - Server marker advances **only after** the manifest is atomically published (no lost changes).
> - **Weekly `parallel` reconcile** is the correctness backstop (≤7-day convergence).
>
> **Recommended three tracks:** initial = `parallel` Deployment · daily = `incremental` CronJob · weekly = `parallel` reconcile CronJob.
>
> **Port:** 8787 | **Delete:** Disabled | **Logging:** Console only | **Namespace:** ea-pmc
>
> **One image, selectable behavior** via `SYNC_MODE` env var:
> - `standard` — single rsync (original)
> - `parallel` — N concurrent workers split by top-level folder (faster walk)
> - `incremental` — pull only changed files via the server manifest (freshness-guarded, skip full walk)
```

- [ ] **Step 2: Verify**

Run:
```bash
grep -n "v3.14 fast-daily contract" cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n "COMPLETE <epoch> <count>" cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: one hit each.

- [ ] **Step 3: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: advertise v3.14 fast-daily manifest contract"
```

---

## Task 3: Rewrite §4.3 `generate-manifest.sh` (parallel walk + atomic sentinel)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§4.3 — the bash code block under "### 4.3 File: `cluster-b/scripts/generate-manifest.sh`")

- [ ] **Step 1: Replace the entire §4.3 bash code block**

Replace everything between the opening ```` ```bash ```` and closing ```` ``` ```` of §4.3 (the script currently starting `#!/bin/bash` / `# Manifest Generator (Cluster B)` and ending `log "Manifest written to $MANIFEST. Done."`) with this `NEW` script:

```bash
#!/bin/bash
#############################################
# Manifest Generator v3.14 (Cluster B)
# Parallel change-list for incremental mode.
#   - parallel `find` split by top-level folder
#   - conservative marker: advance ONLY after atomic publish
#   - atomic publish + "# COMPLETE <epoch> <count>" sentinel
#   - writes to <source>/.sync-state/manifest.txt
#############################################
set +e

SOURCE_PATH="${SOURCE_PATH:-/mnt/nas-source}"
STATE_DIR="${STATE_DIR:-/state}"
STATE_SUBDIR="${STATE_SUBDIR:-.sync-state}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-6}"

MARKER="${STATE_DIR}/last-sync-marker"
CANDIDATE="${STATE_DIR}/last-sync-marker.candidate"

MANIFEST_DIR="${SOURCE_PATH}/${STATE_SUBDIR}"
MANIFEST="${MANIFEST_DIR}/manifest.txt"
MANIFEST_TMP="${MANIFEST_DIR}/manifest.txt.tmp"
WORK_DIR="$(mktemp -d)"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$STATE_DIR" "$MANIFEST_DIR"

log "========================================"
log "Manifest Generator v3.14 (parallel)"
log "  Source:   $SOURCE_PATH"
log "  Manifest: $MANIFEST"
log "  Workers:  $PARALLEL_WORKERS"
log "========================================"

cd "$SOURCE_PATH" || { log "ERROR: cannot cd to $SOURCE_PATH"; exit 1; }

# Capture scan-start BEFORE walking. Because the marker becomes this start
# time, any file changed *during* the scan/transfer is re-caught next run
# (redundant at worst, never lost).
touch "$CANDIDATE"

# First run: no marker yet -> signal a full sync (with sentinel so the
# client's freshness guard accepts it like any other manifest).
if [ ! -f "$MARKER" ]; then
    log "No marker — first run. Signaling FULL_SYNC."
    EPOCH=$(date +%s)
    {
        echo "FULL_SYNC"
        echo "# COMPLETE ${EPOCH} 1"
    } > "$MANIFEST_TMP"
    mv -f "$MANIFEST_TMP" "$MANIFEST"
    mv -f "$CANDIDATE" "$MARKER"
    log "FULL_SYNC manifest published (epoch ${EPOCH}). Done."
    exit 0
fi

# One worker per top-level directory. cwd is SOURCE_PATH, and we pass the
# top dir as a relative name, so `-print` yields module-root-relative paths
# (e.g. "Folder1/sub/file") — exactly what rsync --files-from needs.
# The prune set is hardcoded (static) to avoid exporting arrays to xargs.
run_worker() {
    local top="$1"
    local out="${WORK_DIR}/part.$$.${RANDOM}"
    find "$top" \
        \( -name '.snapshot' -o -name '.snapshots' -o -name '.zfs' \
           -o -name '@Recently-Snapshot' -o -name '@Recycle' -o -name '#recycle' \
           -o -name '@eaDir' -o -name '@tmp' -o -name "${STATE_SUBDIR}" \) -prune \
        -o -type f -newer "$MARKER" -print > "$out"
}
export -f run_worker
export WORK_DIR MARKER STATE_SUBDIR

log "Walking top-level folders in parallel..."
find . -maxdepth 1 -mindepth 1 -type d -printf '%P\n' \
    | xargs -r -P "$PARALLEL_WORKERS" -I {} bash -c 'run_worker "$@"' _ {}

# Top-level loose files (not under any subdir)
find . -maxdepth 1 -type f -newer "$MARKER" -printf '%P\n' > "${WORK_DIR}/part.toplevel"

# Assemble (sorted for deterministic output)
cat "${WORK_DIR}"/part.* 2>/dev/null | LC_ALL=C sort > "${WORK_DIR}/manifest.body"
COUNT=$(wc -l < "${WORK_DIR}/manifest.body")

# Atomic publish: body + sentinel -> tmp -> mv into place
EPOCH=$(date +%s)
{
    cat "${WORK_DIR}/manifest.body"
    echo "# COMPLETE ${EPOCH} ${COUNT}"
} > "$MANIFEST_TMP"
mv -f "$MANIFEST_TMP" "$MANIFEST"

# Advance marker ONLY after a successful atomic publish.
mv -f "$CANDIDATE" "$MARKER"

log "Manifest published: ${COUNT} changed files (epoch ${EPOCH})."
log "Marker advanced. Done."
```

- [ ] **Step 2: Add a one-line note above the block**

Find the §4.3 intro line:
```markdown
> Used only for `incremental` mode. Produces the changed-file list.
```
Replace with:
```markdown
> Used only for `incremental` mode. Produces the changed-file list at `<source>/.sync-state/manifest.txt`, parallelized by top-level folder, published atomically with a `# COMPLETE <epoch> <count>` sentinel. The marker advances only after publish.
```

- [ ] **Step 3: Syntax-check the new script**

Using the Read tool, copy the new §4.3 script body into `/tmp/gen.sh` (just the bash content, no fence lines), then:
```bash
bash -n /tmp/gen.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK` (no parser errors).

- [ ] **Step 4: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "feat: parallel manifest generator with atomic sentinel publish"
```

---

## Task 4: Add `.sync-state/` to the server module exclude (§5.2)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§5.2 `configmap-rsyncd.yaml`)

- [ ] **Step 1: Edit the exclude line**

`OLD`:
```yaml
        exclude = .snapshot/ .snapshots/ .zfs/ @Recently-Snapshot/ @Recycle/ #recycle/ @eaDir/ @tmp/
```
`NEW`:
```yaml
        exclude = .snapshot/ .snapshots/ .zfs/ @Recently-Snapshot/ @Recycle/ #recycle/ @eaDir/ @tmp/ .sync-state/
```

- [ ] **Step 2: Verify**

Run:
```bash
grep -n "exclude = .snapshot" cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: the line now ends with `.sync-state/`. (The client still fetches the manifest *explicitly* by name, so excluding `.sync-state/` from the bulk data sync is safe.)

- [ ] **Step 3: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: exclude .sync-state/ from server data module"
```

---

## Task 5: Update the manifest CronJob (§6.2) for lead time + new env

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§6.2 `cronjob-manifest.yaml`)

- [ ] **Step 1: Give it generous lead time + comment**

`OLD`:
```yaml
spec:
  # Run 10 min BEFORE the client incremental sync
  schedule: "50 */2 * * *"
```
`NEW`:
```yaml
spec:
  # Run with generous lead time before the daily client window. Exact timing
  # no longer matters: the client only consumes a manifest carrying the
  # "# COMPLETE" sentinel, so a slow/overrunning run is never half-read.
  schedule: "0 1 * * *"
```

- [ ] **Step 2: Add the new env vars to the manifest container**

`OLD`:
```yaml
              env:
                - name: SOURCE_PATH
                  value: "/mnt/nas-source"
                - name: STATE_DIR
                  value: "/state"
```
`NEW`:
```yaml
              env:
                - name: SOURCE_PATH
                  value: "/mnt/nas-source"
                - name: STATE_DIR
                  value: "/state"
                - name: STATE_SUBDIR
                  value: ".sync-state"
                - name: PARALLEL_WORKERS
                  value: "8"            # tune to manifest-pod CPU; speeds the find walk
```

- [ ] **Step 3: Verify the source mount stays writable**

Run:
```bash
awk '/### 6.2 /{f=1} f&&/readOnly: false/{print NR": "$0}' cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: at least one `readOnly: false` under §6.2's `nas-source` NFS volume (the manifest job writes `.sync-state/`). If missing, the volume there must be `readOnly: false`.

- [ ] **Step 4: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: manifest CronJob lead-time schedule + parallel/state env"
```

---

## Task 6: Rewrite §8.4 `nas-sync-incremental.sh` (freshness guard + skip/alert)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§8.4 — the bash code block under "### 8.4 File: `cluster-a/scripts/nas-sync-incremental.sh`")

- [ ] **Step 1: Replace the entire §8.4 bash code block**

Replace everything between the opening ```` ```bash ```` and closing ```` ``` ```` of §8.4 (currently `#!/bin/bash` / `# NAS Sync — INCREMENTAL mode` ... ending `exit $SYNC_EXIT`) with this `NEW` script:

```bash
#!/bin/bash
#############################################
# NAS Sync — INCREMENTAL mode v3.14
# Pull only changed files from the server manifest.
#   - explicit manifest fetch from .sync-state/
#   - freshness guard: sentinel + epoch > last-consumed
#   - stale/missing manifest -> skip + alert (exit non-zero)
#   - record last-consumed ONLY on success
#############################################
set +e

REMOTE_HOST="${REMOTE_HOST:-nas-sync.cluster-b.example.com}"
REMOTE_PORT="${REMOTE_PORT:-8787}"
REMOTE_MODULE="${REMOTE_MODULE:-nas-data}"
REMOTE_USER="${REMOTE_USER:-syncuser}"
LOCAL_NAS_PATH="${LOCAL_NAS_PATH:-/mnt/nas-target}"
RSYNC_PASSWORD_FILE="${RSYNC_PASSWORD_FILE:-/userapp/config/rsync.password}"
EXCLUDE_FILE="${EXCLUDE_FILE:-/userapp/config/rsync-exclude.txt}"
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-14400}"
STATE_SUBDIR="${STATE_SUBDIR:-.sync-state}"
MANIFEST_REMOTE="${MANIFEST_REMOTE:-${STATE_SUBDIR}/manifest.txt}"

MANIFEST_LOCAL="/tmp/sync-manifest.txt"
MANIFEST_CLEAN="/tmp/sync-manifest.clean"
LAST_CONSUMED="${LOCAL_NAS_PATH}/${STATE_SUBDIR}/last-consumed-manifest"
REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

RSYNC_FLAGS="-a --whole-file --partial --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

START=$(date +%s)
log "=== NAS SYNC (incremental v3.14) ==="

# --- Pre-flight ---
[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null || die "Remote not reachable"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

# --- Fetch manifest explicitly ---
rm -f "$MANIFEST_LOCAL"
log "Fetching manifest ($MANIFEST_REMOTE)..."
rsync -a --password-file="$RSYNC_PASSWORD_FILE" \
    "${REMOTE_URL}/${MANIFEST_REMOTE}" "$MANIFEST_LOCAL" 2>&1
[ -f "$MANIFEST_LOCAL" ] || die "Manifest fetch failed — skipping run (ALERT)"

# --- Freshness guard ---
SENTINEL=$(grep '^# COMPLETE ' "$MANIFEST_LOCAL" | tail -1)
[ -n "$SENTINEL" ] || die "Manifest has no completion sentinel — incomplete/stale, skipping (ALERT)"
MANIFEST_EPOCH=$(echo "$SENTINEL" | awk '{print $3}')
case "$MANIFEST_EPOCH" in
    ''|*[!0-9]*) die "Manifest sentinel epoch invalid ('$MANIFEST_EPOCH') — skipping (ALERT)" ;;
esac

mkdir -p "$(dirname "$LAST_CONSUMED")"
LAST_EPOCH=0
[ -f "$LAST_CONSUMED" ] && LAST_EPOCH=$(cat "$LAST_CONSUMED" 2>/dev/null)
case "$LAST_EPOCH" in ''|*[!0-9]*) LAST_EPOCH=0 ;; esac

if [ "$MANIFEST_EPOCH" -le "$LAST_EPOCH" ]; then
    die "Manifest epoch ${MANIFEST_EPOCH} not newer than last-consumed ${LAST_EPOCH} — stale, skipping (ALERT)"
fi
log "OK Manifest fresh (epoch ${MANIFEST_EPOCH} > ${LAST_EPOCH})"

# --- Sync ---
if grep -q '^FULL_SYNC$' "$MANIFEST_LOCAL"; then
    log "FULL_SYNC signaled — full pull"
    rsync $RSYNC_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
    SYNC_EXIT=$?
else
    # Strip the sentinel/comment + blank lines; feed only real paths.
    grep -v '^#' "$MANIFEST_LOCAL" | grep -v '^[[:space:]]*$' > "$MANIFEST_CLEAN"
    CHANGED=$(wc -l < "$MANIFEST_CLEAN")
    log "Incremental: ${CHANGED} changed files"
    if [ "$CHANGED" -eq 0 ]; then
        log "Nothing changed."
        SYNC_EXIT=0
    else
        rsync $RSYNC_FLAGS --files-from="$MANIFEST_CLEAN" \
            "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
        SYNC_EXIT=$?
    fi
fi

# --- Record last-consumed ONLY on success (0 or 24=vanished-source-files) ---
if [ "$SYNC_EXIT" -eq 0 ] || [ "$SYNC_EXIT" -eq 24 ]; then
    echo "$MANIFEST_EPOCH" > "$LAST_CONSUMED"
    log "Recorded last-consumed epoch ${MANIFEST_EPOCH} (rsync exit ${SYNC_EXIT})"
    FINAL_EXIT=0
else
    log_error "Sync failed (exit ${SYNC_EXIT}) — last-consumed NOT advanced; retry next run"
    FINAL_EXIT=$SYNC_EXIT
fi

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: exit=$FINAL_EXIT, ${DUR}s ==="
exit $FINAL_EXIT
```

- [ ] **Step 2: Syntax-check the new script**

Using the Read tool, copy the new §8.4 script body into `/tmp/inc.sh` (bash content only, no fence lines), then:
```bash
bash -n /tmp/inc.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 3: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "feat: incremental client with manifest freshness guard + skip/alert"
```

---

## Task 7: Add `.sync-state/` to the client exclude list (§9A.1)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§9A.1 `configmap-exclude.yaml`)

- [ ] **Step 1: Add the entry**

`OLD`:
```yaml
    @eaDir/
    @tmp/
    System Volume Information/
```
`NEW`:
```yaml
    @eaDir/
    @tmp/
    .sync-state/
    System Volume Information/
```

- [ ] **Step 2: Verify**

```bash
grep -n ".sync-state/" cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: hits in the §5.2 module exclude, this §9A.1 list, and the contract/intro text — not just one.

- [ ] **Step 3: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: exclude .sync-state/ from client data sync"
```

---

## Task 8: Make the daily client CronJob daily + non-retrying (§9A.2)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§9A.2 `cronjob-client.yaml`)

- [ ] **Step 1: Daily schedule**

`OLD`:
```yaml
spec:
  schedule: "0 */2 * * *"
  concurrencyPolicy: Forbid
```
`NEW`:
```yaml
spec:
  schedule: "0 3 * * *"          # daily, after the manifest job's lead time (§6.2 = 01:00)
  concurrencyPolicy: Forbid
```

- [ ] **Step 2: Don't retry a skip**

`OLD`:
```yaml
      activeDeadlineSeconds: 86400
      backoffLimit: 2
```
`NEW`:
```yaml
      activeDeadlineSeconds: 86400
      backoffLimit: 0          # a stale-manifest skip won't fix itself by retrying; wait for next run
```

- [ ] **Step 3: Confirm SYNC_MODE + add STATE_SUBDIR**

`OLD`:
```yaml
                - name: SYNC_MODE
                  value: "incremental"          # ◄ standard | parallel | incremental
                - name: PARALLEL_WORKERS
                  value: "6"                     # used if SYNC_MODE=parallel
```
`NEW`:
```yaml
                - name: SYNC_MODE
                  value: "incremental"          # daily fast path — do not change here
                - name: STATE_SUBDIR
                  value: ".sync-state"
                - name: PARALLEL_WORKERS
                  value: "6"                     # used if SYNC_MODE=parallel
```

- [ ] **Step 4: Verify**

```bash
grep -n 'schedule: "0 3 \* \* \*"' cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n "backoffLimit: 0" cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: one hit each.

- [ ] **Step 5: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: daily incremental CronJob (daily schedule, backoffLimit 0)"
```

---

## Task 9: Add the weekly reconcile CronJob (NEW §9A.3)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (insert a new subsection after the §9A.2 `kubectl apply` block, before the `---` that starts §10)

- [ ] **Step 1: Insert the new subsection**

Find the end of §9A.2 (the apply block):
```bash
kubectl config use-context cluster-a
kubectl apply -f cluster-a/namespace.yaml
kubectl apply -f cluster-a/configmap-exclude.yaml
kubectl apply -f cluster-a/secret-password.yaml
kubectl apply -f cluster-a/cronjob-client.yaml
```
Immediately **after** that fenced block (and its trailing blank line), insert:

````markdown
### 9A.3 File: `cluster-a/cronjob-reconcile.yaml` (weekly correctness backstop)

> The daily `incremental` path is fast but best-effort: if a daily run fails *after* the server marker advanced, those files won't reappear in future manifests. This weekly `parallel` full reconcile does a complete bilateral comparison and self-heals any drift (≤7-day convergence). No `--delete` — still additive.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nas-sync-reconcile
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: client
    track: reconcile
spec:
  schedule: "0 2 * * 0"          # Sundays 02:00 — off-hours full walk is acceptable
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    metadata:
      labels:
        app: nas-sync
        role: client
        track: reconcile
    spec:
      activeDeadlineSeconds: 86400
      backoffLimit: 2
      template:
        metadata:
          labels:
            app: nas-sync
            role: client
            track: reconcile
        spec:
          containers:
            - name: nas-sync-client
              image: your-registry.example.com/nas-sync-client:3.13   # ◄ MODIFY
              imagePullPolicy: Always
              env:
                - name: TZ
                  value: "Asia/Taipei"
                - name: SYNC_MODE
                  value: "parallel"             # full bilateral reconcile
                - name: PARALLEL_WORKERS
                  value: "6"
                - name: REMOTE_HOST
                  value: "ISTIO_EXTERNAL_IP_HERE"  # ◄ MODIFY
                - name: REMOTE_PORT
                  value: "8787"
                - name: REMOTE_MODULE
                  value: "nas-data"
                - name: REMOTE_USER
                  value: "syncuser"
                - name: LOCAL_NAS_PATH
                  value: "/mnt/nas-target"
                - name: SYNC_DIRECTION
                  value: "pull"
                - name: RSYNC_TIMEOUT
                  value: "14400"
                - name: RSYNC_PASSWORD_FILE
                  value: "/userapp/config/rsync.password"
                - name: EXCLUDE_FILE
                  value: "/userapp/config/rsync-exclude.txt"
                - name: SIDECAR_QUIT_ENABLED
                  value: "true"
              volumeMounts:
                - name: nas-target
                  mountPath: /mnt/nas-target
                - name: exclude-config
                  mountPath: /userapp/config/rsync-exclude.txt
                  subPath: rsync-exclude.txt
                  readOnly: true
                - name: rsync-password
                  mountPath: /userapp/config/rsync.password
                  subPath: rsync.password
                  readOnly: true
              resources:
                requests:
                  memory: "512Mi"
                  cpu: "500m"
                limits:
                  memory: "4Gi"
                  cpu: "4000m"
          restartPolicy: Never
          volumes:
            - name: nas-target
              persistentVolumeClaim:
                claimName: nas-a-target-pvc       # ◄ MODIFY
            - name: exclude-config
              configMap:
                name: rsync-exclude-config
            - name: rsync-password
              secret:
                secretName: rsync-password
                defaultMode: 0400
```

```bash
kubectl apply -f cluster-a/cronjob-reconcile.yaml
```
````

- [ ] **Step 2: Verify**

```bash
grep -n "nas-sync-reconcile" cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n "### 9A.3 " cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: one hit each.

- [ ] **Step 3: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "feat: weekly parallel reconcile CronJob (correctness backstop)"
```

---

## Task 10: Rewrite §12 "Choosing Sync Mode" to the three-track model

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§12)

- [ ] **Step 1: Replace the §12 recommendation block**

`OLD`:
```markdown
**Recommended for your scale (7.4M folders, 0.17% change):**

```
Routine (every 2h):   CronJob + SYNC_MODE=incremental
Weekly reconcile:     CronJob + SYNC_MODE=parallel (Sunday 2 AM)
Initial bulk sync:    Deployment + SYNC_MODE=parallel (no time limit)
```
```

`NEW`:
```markdown
**Recommended for your scale (7.4M files, ~0.17% daily change) — three tracks:**

```
Initial bulk sync:  Deployment + SYNC_MODE=parallel   (one-time, no time limit, §10B)
Daily fast path:    CronJob    + SYNC_MODE=incremental (§9A.2, manifest --files-from)
Weekly reconcile:   CronJob    + SYNC_MODE=parallel    (§9A.3, Sun 02:00, correctness backstop)
```

**Why this is fast:** the daily client never walks the tree. The server's manifest CronJob (§6)
finds changes ahead of time (parallelized) and the client pulls only that list via `--files-from`,
so daily work scales with the *change rate*, not the 6 TB. Cost model: ~12K changed-file stats vs
~7.4M × 2-side walk for a plain sync.

**The manifest/marker/sentinel contract:**
- Server writes `<source>/.sync-state/manifest.txt`, ending with `# COMPLETE <epoch> <count>`.
- Server advances its marker **only after** the manifest is atomically published (no lost changes).
- Client refuses any manifest missing the sentinel, or whose epoch ≤ its last-consumed epoch
  (`<target>/.sync-state/last-consumed-manifest`): it **skips + alerts** (exits non-zero) rather
  than fall back to a slow full sync.
- Client records last-consumed **only on a successful** sync.
- A daily failure after the marker advanced is healed by the **weekly parallel reconcile** (≤7 days).
```

- [ ] **Step 2: Verify**

```bash
grep -n "three tracks" cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n "manifest/marker/sentinel contract" cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: one hit each.

- [ ] **Step 3: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: rewrite Choosing Sync Mode for three-track design + contract"
```

---

## Task 11: Add troubleshooting entries (§13)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§13)

- [ ] **Step 1: Replace the existing "Incremental: manifest not found" subsection**

`OLD`:
```markdown
### Incremental: manifest not found

```bash
# Check manifest job ran and wrote the file
kubectl logs job/<manifest-job> -n ea-pmc
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.sync-manifest.txt
```
```

`NEW`:
```markdown
### Incremental: client skipped with "stale/missing manifest (ALERT)"

By design the client **skips + exits non-zero** (Job shows `Failed`) instead of doing a slow
full sync. Diagnose the server manifest:

```bash
# Did the manifest job run and publish a sentinel?
kubectl logs -n ea-pmc job/<manifest-job> | tail
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  tail -1 /mnt/nas-source/.sync-state/manifest.txt        # expect: # COMPLETE <epoch> <count>

# Compare epochs: manifest sentinel vs client's last-consumed
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  awk '/^# COMPLETE/{print "manifest epoch:",$3}' /mnt/nas-source/.sync-state/manifest.txt
# (client side) cat <target>/.sync-state/last-consumed-manifest
```

If the manifest is genuinely behind, check the manifest CronJob schedule/lead time (§6.2) and
that its `find` walk completes in time. The weekly reconcile (§9A.3) covers any gap meanwhile.

### Manifest job: find walk too slow

```bash
# Raise parallelism and/or manifest-pod CPU
kubectl edit cronjob nas-sync-manifest -n ea-pmc    # bump PARALLEL_WORKERS / CPU limit
# Confirm it finishes before the daily client window (§6.2 schedule vs §9A.2 schedule)
```
```

- [ ] **Step 2: Verify**

```bash
grep -n "stale/missing manifest (ALERT)" cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n "find walk too slow" cross-cluster-rsync-guide-v3.13-consolidated.md
grep -c ".sync-manifest.txt" cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: first two = one hit each; third = `0` (old manifest filename fully retired).

- [ ] **Step 3: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: troubleshooting for stale-manifest skip and slow find walk"
```

---

## Task 12: Update File Checklist + Deploy Order (§14)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.13-consolidated.md` (§14)

- [ ] **Step 1: Add the reconcile job to the Cluster A checklist**

`OLD`:
```markdown
├── cronjob-client.yaml             # 9A.2  ← k8s type 1: CronJob
├── deployment-client.yaml          # 10B.1 ← k8s type 2: Deployment
```
`NEW`:
```markdown
├── cronjob-client.yaml             # 9A.2  ← daily: SYNC_MODE=incremental
├── cronjob-reconcile.yaml          # 9A.3  ← weekly: SYNC_MODE=parallel (backstop)
├── deployment-client.yaml          # 10B.1 ← initial bulk: SYNC_MODE=parallel
```

- [ ] **Step 2: Update the Deploy Order step 7**

`OLD`:
```markdown
7. Choose k8s type:
   • CronJob    → cluster-a/cronjob-client.yaml    (Step 6A)
   • Deployment → cluster-a/deployment-client.yaml (Step 6B)
   Set SYNC_MODE in whichever you deploy.
```
`NEW`:
```markdown
7. Deploy the three tracks:
   • Initial bulk → cluster-a/deployment-client.yaml  (SYNC_MODE=parallel, Step 6B);
     when it logs COMPLETE, tear it down (§10B.2).
   • Daily        → cluster-a/cronjob-client.yaml     (SYNC_MODE=incremental, §9A.2)
   • Weekly       → cluster-a/cronjob-reconcile.yaml  (SYNC_MODE=parallel, §9A.3)
```

- [ ] **Step 3: Verify**

```bash
grep -n "cronjob-reconcile.yaml" cross-cluster-rsync-guide-v3.13-consolidated.md
```
Expected: hits in §9A.3, the checklist, and the deploy-order text.

- [ ] **Step 4: Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: file checklist + deploy order for three-track design"
```

---

## Task 13: Update `CLAUDE.md` to reflect the v3.14 contract

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the incremental bullet in "Non-Obvious Design Decisions"**

`OLD`:
```markdown
- **`incremental` mode requires the manifest CronJob on Cluster B** (`§6`). `generate-manifest.sh` writes `.sync-manifest.txt` *into the source NAS* (so that NFS mount must be `readOnly: false`), using a marker file + `find -newer`. First run emits the literal `FULL_SYNC`; the client falls back to a full sync if the manifest is missing or signals `FULL_SYNC`.
```

`NEW`:
```markdown
- **`incremental` mode requires the manifest CronJob on Cluster B** (`§6`). `generate-manifest.sh` does a **parallelized** `find -newer` and publishes `<source>/.sync-state/manifest.txt` **atomically** with a `# COMPLETE <epoch> <count>` sentinel; the marker advances **only after** publish (so a crash never loses changes). The daily client (`§8.4`) refuses any manifest lacking the sentinel or not newer than its `last-consumed` epoch — it **skips + exits non-zero (alert)** rather than silently doing a slow full sync. A failed daily run is healed by the **weekly `parallel` reconcile** (`§9A.3`, ≤7-day convergence). See the design spec at `docs/superpowers/specs/2026-06-20-fast-daily-nas-sync-design.md`.
```

- [ ] **Step 2: Update the two-axes "SYNC_MODE" line to mention the three-track recommendation**

`OLD`:
```markdown
   - `incremental` → `nas-sync-incremental.sh` (syncs only files in a server-generated manifest)
```
`NEW`:
```markdown
   - `incremental` → `nas-sync-incremental.sh` (pulls only files in a server-generated manifest; the fast daily path)

   **Recommended three-track deployment:** initial = `parallel` Deployment (one-time) · daily = `incremental` CronJob · weekly = `parallel` reconcile CronJob (backstop). See `§12` and the spec under `docs/superpowers/specs/`.
```

- [ ] **Step 3: Verify**

```bash
grep -n "COMPLETE <epoch> <count>" CLAUDE.md
grep -c ".sync-manifest.txt" CLAUDE.md
```
Expected: first ≥1; second = `0`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for v3.14 manifest contract + three tracks"
```

---

## Task 14: Consistency sweep + final syntax check

**Files:**
- Verify only: `cross-cluster-rsync-guide-v3.13-consolidated.md`, `CLAUDE.md`

- [ ] **Step 1: No stale references remain**

```bash
grep -rn ".sync-manifest.txt" . ; echo "exit=$?"
```
Expected: no matches (`exit=1` from grep). The old single-file manifest name is fully replaced by `.sync-state/manifest.txt`.

- [ ] **Step 2: Both rewritten scripts still parse**

Re-using `/tmp/gen.sh` and `/tmp/inc.sh` from Tasks 3 and 6 (re-copy from the guide if edited since):
```bash
bash -n /tmp/gen.sh && bash -n /tmp/inc.sh && echo "BOTH OK"
```
Expected: `BOTH OK`.

- [ ] **Step 3: Cross-references resolve**

```bash
for s in "§9A.3" "9A.3" ".sync-state/manifest.txt" "# COMPLETE" "last-consumed-manifest" "nas-sync-reconcile"; do
  printf '%-28s ' "$s"; grep -c "$s" cross-cluster-rsync-guide-v3.13-consolidated.md
done
```
Expected: every count ≥ 1 (each new concept is referenced somewhere).

- [ ] **Step 4: Schedules are coherent (manifest before daily client)**

Confirm by eye: §6.2 manifest `schedule: "0 1 * * *"` (01:00) runs before §9A.2 client `schedule: "0 3 * * *"` (03:00), and §9A.3 reconcile is `"0 2 * * 0"` (Sun 02:00). Adjust if your timezone/window differs.

- [ ] **Step 5: Final commit + optional tag**

```bash
git add -A
git commit -m "docs: v3.14 consistency sweep (fast daily sync complete)"
git tag v3.14-fast-daily   # optional
```

---

## Self-review notes (already reconciled against the spec)

- **Spec §5.1 (initial parallel):** covered by existing §10B; T12 deploy-order makes it explicit.
- **Spec §5.2 (daily client + freshness guard + client state):** T6 (script), T8 (CronJob).
- **Spec §5.3 (manifest generator: parallel/marker/sentinel/prune/FULL_SYNC+sentinel):** T3.
- **Spec §5.4 (weekly reconcile):** T9.
- **Spec §5.5 (storage topology — manifest on source `.sync-state/`, marker on PVC, last-consumed on target):** T3 + T5 + T6.
- **Spec §5.6 (exclude `.sync-state/`, `readOnly:false`, `backoffLimit:0`):** T4, T5, T7, T8.
- **Spec §7/§8 (failure modes, ≤7-day guarantee):** encoded in T6 behavior + T9 backstop; documented in T10/T11.
- **Naming consistency:** `manifest.txt`, `# COMPLETE <epoch> <count>`, `STATE_SUBDIR=.sync-state`, `last-consumed-manifest`, env `MANIFEST_REMOTE` — used identically across T3/T5/T6/T8/T10/T13.
- **rsync exit 24** treated as success in T6 (vanished source files between manifest gen and pull) — intentional.
