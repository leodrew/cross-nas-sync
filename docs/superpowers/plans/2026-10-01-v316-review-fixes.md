# v3.16 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use anthropic-skills:subagent-driven-development (recommended) or anthropic-skills:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `cross-cluster-rsync-guide-v3.16-consolidated.md` with the fixes in
`docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md` (findings F1–F7), plus a static
and a runtime regression suite that prove them.

**Architecture:** The guide's fenced blocks are the deliverable. Each task edits the new v3.16
guide, and its correctness is proven by `scripts/test-guide-behavior.sh` (new): that suite
extracts the scripts from the guide and runs them against a real rsync daemon, with tini as
PID 1 where signals matter. Tasks are ordered test-first: Task 2 adds the suite and shows
every case red. Each later task turns specific cases green.

**Tech Stack:** bash, rsync 3.2.7 (ubuntu:24.04), tini, Debian cron, util-linux (`unshare`,
`flock`), perl (perl-base), Kubernetes/Istio YAML, markdown.

**Provenance:** every edit, block and file in this plan was replayed task by task on a copy
of the repo before the plan was written. After each task `check-guide.sh` passed, and the
behavior cases listed for that task turned green. The "Expected" outputs below are from that
replay.

## Global Constraints

- Never add `--delete` in any form. Target-only files are preserved by policy.
- Never renumber existing sections. The new sections are **§4.7** and **§8.11**.
- A new script means four edits: its section, the Dockerfile `COPY`, the `dos2unix` + CRLF-guard lists in that Dockerfile, and the §14 checklist.
- Every block stays copy-paste-ready, with LF line endings only. Keep these placeholders intact: `your-registry.example.com`, `ISTIO_EXTERNAL_IP_HERE`, `◄ MODIFY`.
- `bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md` must pass before **every** commit.
- `cross-cluster-rsync-guide-v3.15-consolidated.md` and older guides are history. Never edit them.
- Fixed conventions: port `8787`, namespace `ea-pmc`, console-only logging, `--whole-file`.
- **Rolling upgrade:** a v3.16 server must keep serving v3.15 clients, rollback stays a tag change, and there is no state migration.
- **Exit codes:**
  - `75` = generator lock held; the run did nothing.
  - `143` = interrupted by SIGTERM.
  - rsync `23`/`24` remain success, via `rsync_rc_ok`.
- **Defaults:**
  - `LOCK_HEARTBEAT=60`
  - `LOCK_STALE=600`
  - `CHUNK_RETRY_WAIT=30`
  - `SHUTDOWN_WAIT=50`
  - `terminationGracePeriodSeconds: 60`
- `scripts/test-guide-behavior.sh --native` needs root on Linux, and writes `/userapp/scripts`, `/etc/cron.d/nas-sync` and `/etc/environment` (the last is restored afterwards). Run it only in a disposable container or CI. The default mode (no `--native`) runs inside docker.
- **Edits are exact string replacements.** Each "Find" text must occur exactly the stated number of times. If it does not, stop: the file is not in the state this plan expects.
- Commit messages end with the attribution trailer that the executing session requires.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `cross-cluster-rsync-guide-v3.16-consolidated.md` | **Create** (copy of v3.15, then edited) | The deliverable: every script, Dockerfile and manifest |
| guide §4.7 `cluster-b/scripts/nas-sync-state-lock.sh` | **New section** | Per-job NFS `mkdir` lock with heartbeat, sourced by §4.3 and §4.6 |
| guide §8.11 `cluster-a/scripts/nas-sync-lib.sh` | **New section** | `list_top_dirs`, `wait_child`, `term_trap_install`, `check_term`; sourced by every client script |
| guide §4.3, §4.6 | Replace blocks | Lock, per-run temp names, atomic meta; generation-named chunks |
| guide §8.3 | Replace block | Generation-checked chunk fetch with one retry; any-character folder names; non-recursive top-level pass; invariants |
| guide §8.2, §8.4, §8.5, §8.6, §8.7, §8.10 | Exact edits | SIGTERM handling; verify tier 2 via `list_top_dirs` |
| guide §4.4, §4.5, §6.1, §6.3, §8.8, §8.9, §9A.2, §9A.4, §9A.5, §10B.1, §11, §13, §14, appendix | Exact edits | Dockerfiles, grace periods, docs |
| `scripts/test-guide-behavior.sh` | **Create** | Runtime suite: cases `names loose swap lock signal deploy` |
| `scripts/check-guide.sh` | Modify | Section 10: v3.16 regression assertions |
| `docs/nas-sync-operations-runbook.md`, `CLAUDE.md` | Modify | v3.16 references, lock-held procedures, new decisions |
| `docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md` | Modify (1 line) | rc 23 wording matches the implementation |

---
### Task 1: Create the v3.16 guide (version bump only)

**Files:**
- Create: `cross-cluster-rsync-guide-v3.16-consolidated.md` (copy of v3.15)

**Interfaces:**
- Produces: the file every later task edits. Image tags `:3.16`, `LABEL version="3.16"`.

- [ ] **Step 1: Create the file**

```bash
cp cross-cluster-rsync-guide-v3.15-consolidated.md cross-cluster-rsync-guide-v3.16-consolidated.md
```

- [ ] **Step 2: Title** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
# Cross-Cluster NAS Rsync — Consolidated Guide v3.15 (Multi-Target, Hardened)
```

Replace with:

```text
# Cross-Cluster NAS Rsync — Consolidated Guide v3.16 (Multi-Target, Hardened)
```

- [ ] **Step 3: Server image tags** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly 5 times — replace **all 5**):

```text
nas-sync-server:3.15
```

Replace with:

```text
nas-sync-server:3.16
```

- [ ] **Step 4: Client image tags** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly 8 times — replace **all 8**):

```text
nas-sync-client:3.15
```

Replace with:

```text
nas-sync-client:3.16
```

- [ ] **Step 5: Dockerfile labels** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly 2 times — replace **all 2**):

```text
LABEL version="3.15"
```

Replace with:

```text
LABEL version="3.16"
```

- [ ] **Step 6: Server entrypoint banner (§4.2)** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
log "NAS Sync Server v3.15 (Cluster B)"
```

Replace with:

```text
log "NAS Sync Server v3.16 (Cluster B)"
```

- [ ] **Step 7: Run the checker**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md
```

Expected:

```text
All checks passed (0 warning(s))
```


- [ ] **Step 8: Commit**

```bash
git add cross-cluster-rsync-guide-v3.16-consolidated.md
git commit -m "v3.16: create guide from v3.15 (title, image tags, labels)"
```

---
### Task 2: Behavior suite (all cases red)

**Files:**
- Create: `scripts/test-guide-behavior.sh`

**Interfaces:**
- Consumes: section numbers `4.3 4.6 4.7 8.2 8.3 8.4 8.5 8.6 8.7 8.10 8.11` in the guide (each one's first ```` ```bash ```` block becomes a file in `/userapp/scripts/`; missing sections are skipped).
- Produces: `scripts/test-guide-behavior.sh [--slow] [--native] [--case NAME]... [guide.md]`, exit 0 only if every check passes. Cases: `names loose swap lock signal` (+ `deploy` with `--slow`). `NGB_KEEP=1` keeps the workspace and its logs.

- [ ] **Step 1: Write the suite**

Create `scripts/test-guide-behavior.sh` with exactly this content:

````bash
#!/bin/bash
#############################################
# test-guide-behavior.sh — runtime regression suite for the guide's scripts.
#
# check-guide.sh proves the fenced blocks PARSE. This proves they BEHAVE: it extracts
# the scripts from the guide, runs them against a real rsync daemon (tini as PID 1 where
# it matters) and asserts the v3.16 fixes — see
# docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md §10.2.
# Run against the v3.15 guide, every case FAILS: that is the proof it detects the defects.
#
# Usage: scripts/test-guide-behavior.sh [--slow] [--native] [--case NAME]... [guide.md]
#   (default)  re-run inside `docker run --rm --privileged ubuntu:24.04` — works from
#              Windows/MSYS and never touches the host. Pass the guide repo-relative.
#   --native   run on THIS Linux host: needs root, rsync, tini, perl, unshare, nc, flock
#              (+ cron for --slow). It writes /userapp/scripts, /etc/cron.d/nas-sync and
#              /etc/environment (restored afterwards) — use a disposable container or CI.
#   --slow     add the `deploy` case (waits for a cron minute boundary, ~1-2 min).
#   --case X   run only case X (repeatable): names loose swap lock signal deploy
#   NGB_KEEP=1 keep the workspace (logs of every run) and print its path
#############################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOW=0; NATIVE=0; GUIDE=""; ONLY=()
ARGS=("$@")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --slow)   SLOW=1 ;;
        --native) NATIVE=1 ;;
        --case)   shift; ONLY+=("${1:-}") ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *)        GUIDE="$1" ;;
    esac
    shift
done

# ---------------------------------------------------------------- docker re-exec
if [ "$NATIVE" -eq 0 ]; then
    command -v docker >/dev/null 2>&1 \
        || { echo "docker not found. Install it, or use --native inside a disposable Linux container (root)."; exit 2; }
    HOST_DIR=$(cd "$REPO_ROOT" && { pwd -W 2>/dev/null || pwd; })
    MSYS_NO_PATHCONV=1 exec docker run --rm --privileged -v "${HOST_DIR}:/repo" -w /repo ubuntu:24.04 bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null && apt-get install -y -qq rsync tini perl cron procps util-linux \
            netcat-openbsd >/dev/null || { echo "apt-get failed"; exit 2; }
        exec bash scripts/test-guide-behavior.sh --native "$@"' _ "${ARGS[@]}"
fi

cd "$REPO_ROOT" || exit 2
[ -n "$GUIDE" ] || GUIDE=$(ls -1 cross-cluster-rsync-guide-v*.md | sort -V | tail -1)
[ -f "$GUIDE" ] || { echo "guide not found: $GUIDE"; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "--native needs root"; exit 2; }
for t in rsync tini perl unshare nc flock mountpoint; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t"; exit 2; }
done

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }   # check "<label>" "<shell test>"
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- workspace + cleanup
T=$(mktemp -d /tmp/ngb.XXXXXX); chmod 755 "$T"
DAEMON_PID=""
HAD_USERAPP=0; [ -d /userapp ] && HAD_USERAPP=1
cp -a /etc/environment "$T/environment.bak" 2>/dev/null
SHIM_MARK="# ngb-rsync-shim"
cleanup() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    awk -v t="$T" '$2 ~ "^" t {print $2}' /proc/mounts | sort -r | while read -r m; do umount -l "$m"; done
    grep -qs "$SHIM_MARK" /usr/local/bin/rsync && rm -f /usr/local/bin/rsync
    rm -f /etc/ngb-rsync-shim.conf /etc/cron.d/nas-sync /var/lock/nas-sync.lock
    if [ -f "$T/environment.bak" ]; then cp -a "$T/environment.bak" /etc/environment; else rm -f /etc/environment; fi
    [ "$HAD_USERAPP" -eq 0 ] && rm -rf /userapp
    if [ "${NGB_KEEP:-0}" = 1 ]; then echo "workspace kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT
# A shim left by an interrupted earlier run must not be mistaken for the real rsync.
grep -qs "$SHIM_MARK" /usr/local/bin/rsync && rm -f /usr/local/bin/rsync
REAL_RSYNC=$(command -v rsync)

# ---------------------------------------------------------------- install scripts from the guide
extract() {  # extract "<section number>" → that section's first ```bash block, CR-stripped
    awk -v h="### $1 File:" 'index($0,h)==1{f=1;next} f&&/^```bash/{p=1;next} p&&/^```/{exit} p{print}' "$GUIDE" | tr -d '\r'
}
S=/userapp/scripts
rm -rf "$S"; mkdir -p "$S"
while read -r sec file; do
    body=$(extract "$sec")
    [ -n "$body" ] || continue                     # e.g. §4.7/§8.11 do not exist in v3.15
    printf '%s\n' "$body" > "$S/$file"; chmod +x "$S/$file"
done <<'EOF'
4.3 generate-manifests.sh
4.6 generate-chunks.sh
4.7 nas-sync-state-lock.sh
8.2 nas-sync-client.sh
8.3 nas-sync-parallel.sh
8.4 nas-sync-incremental.sh
8.5 dispatch-sync.sh
8.6 run-with-sidecar-quit.sh
8.7 entrypoint-deployment.sh
8.10 nas-sync-verify.sh
8.11 nas-sync-lib.sh
EOF

# ---------------------------------------------------------------- rsync daemon (§5.2-style)
PORT=""
for p in $(seq 18787 18887); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { PORT=$p; break; }
done
[ -n "$PORT" ] || { echo "no free port"; exit 2; }
mkdir -p "$T/src"
cat > "$T/rsyncd.conf" <<EOF
uid = root
gid = root
use chroot = no
reverse lookup = no
pid file = $T/rsyncd.pid
log file = $T/rsyncd.log
[nas-data]
    path = $T/src
    read only = yes
    list = yes
    auth users = syncuser
    secrets file = $T/rsyncd.secrets
    exclude = .snapshot/ .snapshots/ .zfs/ @Recently-Snapshot/ @Recycle/ #recycle/ @eaDir/ @tmp/
EOF
echo 'syncuser:testpw' > "$T/rsyncd.secrets"; chmod 600 "$T/rsyncd.secrets"
echo 'testpw' > "$T/pw"; chmod 600 "$T/pw"
"$REAL_RSYNC" --daemon --no-detach --config="$T/rsyncd.conf" --port="$PORT" --address=127.0.0.1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done

# Client exclude list: the sync-machinery and opinionated lines of §9A.1.
printf '%s\n' '.rsync-partial/' '.nas-sync-state/' '.nas-sync-status/' '*.tmp' '.git/' > "$T/exclude.txt"
export REMOTE_HOST=127.0.0.1 REMOTE_PORT="$PORT" REMOTE_MODULE=nas-data REMOTE_USER=syncuser
export RSYNC_PASSWORD_FILE="$T/pw" EXCLUDE_FILE="$T/exclude.txt"
export PREFLIGHT_RETRIES=2 PREFLIGHT_WAIT=1 STATUS_ENABLED=true CHUNK_RETRY_WAIT=1 TZ=UTC

# rsync shim: slows matching client transfers so a test can act mid-transfer. Config lives in a
# fixed file so that cron-launched runs (which do not inherit our environment) obey it too.
mkdir -p "$T/shim"
cat > "$T/shim/rsync" <<EOF
#!/bin/bash
$SHIM_MARK
bw=""; match=""
[ -f /etc/ngb-rsync-shim.conf ] && . /etc/ngb-rsync-shim.conf
case " \$* " in *" --daemon "*|*" --list-only "*) exec $REAL_RSYNC "\$@" ;; esac
if [ -n "\$bw" ] && { [ -z "\$match" ] || [[ " \$* " == *"\$match"* ]]; }; then
    exec $REAL_RSYNC --bwlimit="\$bw" "\$@"
fi
exec $REAL_RSYNC "\$@"
EOF
chmod +x "$T/shim/rsync"
shim_set() { printf 'bw=%s\nmatch=%s\n' "$1" "${2:-}" > /etc/ngb-rsync-shim.conf; }
shim_off() { rm -f /etc/ngb-rsync-shim.conf; }

fresh_src() { rm -rf "$T/src"; mkdir -p "$T/src"; }
fresh_dst() {  # fresh_dst <name> → echoes a NEW tmpfs mountpoint (the scripts require a mountpoint)
    local d="$T/dst-$1"
    mountpoint -q "$d" 2>/dev/null && umount -l "$d"
    rm -rf "$d"; mkdir -p "$d"
    mount -t tmpfs -o size=1g tmpfs "$d" || return 1
    echo "$d"
}
want() { [ "${#ONLY[@]}" -eq 0 ] && return 0; local c; for c in "${ONLY[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }
files_of() { (cd "$1" && find . \( -name .nas-sync-state -o -name .nas-sync-status -o -name .rsync-partial \) -prune -o -type f -print | sort); }

printf '\033[1m=== %s ===\033[0m  (rsync daemon on 127.0.0.1:%s)\n' "$GUIDE" "$PORT"

# ================================================================ names
if want names; then
    head2 "names — top-level folder names (§8.3 fallback, §8.10 tier 2)"
    fresh_src
    NAMES=( "My folder" "folder" "資料" "John's" "a[1]" "a1" "star*" "starX" " lead" $'tab\tin' $'nl\nx' "-n" "normal" )
    for d in "${NAMES[@]}"; do mkdir -p "$T/src/$d"; printf 'content of <%s>\n' "$d" > "$T/src/$d/f.txt"; done
    echo loose > "$T/src/loose.txt"
    mkdir -p "$T/src/.nas-sync-state/clients/x" "$T/src/.git"
    echo state > "$T/src/.nas-sync-state/clients/x/sync-manifest.txt"; echo cfg > "$T/src/.git/config"
    DST=$(fresh_dst names)
    LOCAL_NAS_PATH="$DST" PARALLEL_WORKERS=3 "$S/nas-sync-parallel.sh" > "$T/names.log" 2>&1
    RC=$?
    check "parallel fallback exits 0 (rc=$RC)" '[ "$RC" -eq 0 ]'
    MIS=""
    for d in "${NAMES[@]}"; do
        [ "$(cat "$DST/$d/f.txt" 2>/dev/null)" = "content of <$d>" ] || MIS="$MIS $(printf '%q' "$d")"
    done
    check "every folder holds its OWN content (space, CJK, quote, glob, newline, -n)${MIS:+ — wrong:$MIS}" '[ -z "$MIS" ]'
    check "sync machinery (.nas-sync-state) is not replicated" '[ ! -e "$DST/.nas-sync-state" ]'
    check "excluded top-level dir (.git) is not replicated" '[ ! -e "$DST/.git" ]'
    check "top-level loose file is synced" '[ -f "$DST/loose.txt" ]'

    LOCAL_NAS_PATH="$DST" VERIFY_MODE=checksum VERIFY_SLICES=1 "$S/nas-sync-verify.sh" > "$T/verify0.log" 2>&1
    RC=$?
    check "verify tier 2 on an in-sync tree: exit 0, drift=0 (rc=$RC)" '[ "$RC" -eq 0 ] && grep -q "VERIFY RESULT .* drift=0 " "$T/verify0.log"'
    for d in "資料" "My folder" "a[1]"; do       # same size, same mtime, different bytes
        f="$DST/$d/f.txt"; [ -f "$f" ] || continue
        t=$(stat -c %Y "$f"); sz=$(stat -c %s "$f")
        head -c "$sz" /dev/zero | tr '\0' 'Z' > "$f"; touch -d "@$t" "$f"
    done
    LOCAL_NAS_PATH="$DST" VERIFY_MODE=checksum VERIFY_SLICES=1 "$S/nas-sync-verify.sh" > "$T/verify1.log" 2>&1
    RC=$?
    DRIFT=$(sed -n 's/^VERIFY RESULT .* drift=\([0-9]*\) .*/\1/p' "$T/verify1.log")
    check "verify tier 2 detects silent corruption in '資料', 'My folder', 'a[1]' (drift=${DRIFT:-?}, rc=$RC)" '[ "$RC" -eq 1 ] && [ "${DRIFT:-0}" -ge 3 ]'
fi

# ================================================================ loose
if want loose; then
    head2 "loose — the top-level pass owns the top level only (§8.3)"
    fresh_src
    mkdir -p "$T/src/deep/inner"; echo x > "$T/src/deep/inner/file"; echo top > "$T/src/top.txt"
    DST=$(fresh_dst loose)
    # xargs that dispatches nothing: whatever reaches the target came from the top-level pass.
    mkdir -p "$T/noxargs"; printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$T/noxargs/xargs"; chmod +x "$T/noxargs/xargs"
    PATH="$T/noxargs:$PATH" LOCAL_NAS_PATH="$DST" "$S/nas-sync-parallel.sh" > "$T/loose.log" 2>&1
    RC=$?
    check "top-level pass copies top-level files" '[ -f "$DST/top.txt" ]'
    check "top-level pass creates top-level dirs" '[ -d "$DST/deep" ]'
    check "top-level pass does NOT recurse (v3.15: -a implied -r → full serial sync)" '[ ! -e "$DST/deep/inner/file" ]'
    check "workers that never ran are detected — not 'all OK' (rc=$RC)" '[ "$RC" -ne 0 ] && ! grep -q "all OK" "$T/loose.log"'
fi

# ================================================================ swap
if want swap; then
    head2 "swap — chunk fetch overlapping the server's swap (§4.6, §8.3)"
    fresh_src
    for d in $(seq -w 1 300); do mkdir -p "$T/src/d$d"; (cd "$T/src/d$d" && touch $(seq -f 'f%02g' 1 80)); done
    export SOURCE_PATH="$T/src" STATE_DIR="$T/src/.nas-sync-state" CHUNK_COUNT=24
    "$S/generate-chunks.sh" > "$T/gen1.log" 2>&1
    check "generation 1 published" '[ -f "$STATE_DIR/common/chunks/chunks.meta" ]'
    for d in $(seq -w 1 300); do echo new > "$T/src/d$d/new-$d"; done      # shifts every round-robin slot
    sleep 1                                                                  # distinct generation id
    DST=$(fresh_dst swap)
    shim_set 60 "/common/chunks/"                                            # ~60 KB/s chunk fetch
    PATH="$T/shim:$PATH" LOCAL_NAS_PATH="$DST" "$S/nas-sync-parallel.sh" > "$T/swap.log" 2>&1 &
    CPID=$!
    for _ in $(seq 1 100); do
        ls /tmp/nas-sync-parallel.*/chunks/ 2>/dev/null | grep -q . && break; sleep 0.1
    done
    sleep 1
    "$S/generate-chunks.sh" > "$T/gen2.log" 2>&1                            # swap mid-fetch
    wait "$CPID"; RC=$?
    shim_off
    unset SOURCE_PATH STATE_DIR CHUNK_COUNT
    MISSING=$(comm -23 <(files_of "$T/src") <(files_of "$DST") | wc -l)
    check "reconcile covers every path despite the mid-fetch swap (missing=$MISSING, rc=$RC)" '[ "$MISSING" -eq 0 ] && [ "$RC" -eq 0 ]'
    check "client never accepted a mixed set (retried or used one generation)" \
        'grep -qE "retrying once|Using [0-9]+ server-generated chunks \(generation=g[0-9]+" "$T/swap.log"'
fi

# ================================================================ lock
if want lock; then
    head2 "lock — overlapping runs of the same generator (§4.3, §4.6, §4.7)"
    fresh_src
    for d in $(seq 1 200); do mkdir -p "$T/src/d$d"; (cd "$T/src/d$d" && touch $(seq -f 'f%g' 1 100)); done
    export SOURCE_PATH="$T/src" STATE_DIR="$T/src/.nas-sync-state" REGISTRY_FILE="$T/clients.txt" CHUNK_COUNT=24
    printf 'nas-a 100000\n' > "$REGISTRY_FILE"
    M="$STATE_DIR/clients/nas-a/sync-manifest.txt"
    # Baselines from solo runs.
    "$S/generate-manifests.sh" > /dev/null 2>&1; sort "$M" > "$T/m.base"
    "$S/generate-chunks.sh" > /dev/null 2>&1; cat "$STATE_DIR"/common/chunks/chunk-*.txt | sort > "$T/c.base"
    rm -rf "$STATE_DIR"
    # A throttled find makes each walk take a few seconds (stands in for 7.4M paths on NFS).
    mkdir -p "$T/slowfind"
    printf '#!/bin/bash\n/usr/bin/find "$@" | awk '"'"'{print; fflush()} NR%%2000==0{system("sleep 0.3")}'"'"'\n' > "$T/slowfind/find"
    chmod +x "$T/slowfind/find"
    for job in manifests chunks; do
        [ "$job" = manifests ] && GEN="$S/generate-manifests.sh" || GEN="$S/generate-chunks.sh"
        PATH="$T/slowfind:$PATH" "$GEN" > "$T/$job.a.log" 2>&1 & APID=$!
        sleep 1.5
        PATH="$T/slowfind:$PATH" "$GEN" > "$T/$job.b.log" 2>&1; RCB=$?
        wait "$APID"; RCA=$?
        check "$job: overlapping second run exits 75, first succeeds (rcA=$RCA rcB=$RCB)" '[ "$RCB" -eq 75 ] && [ "$RCA" -eq 0 ]'
        if [ "$job" = manifests ]; then
            check "$job: published manifest identical to a solo run" 'sort "$M" | cmp -s - "$T/m.base"'
        else
            META_TOTAL=$(awk -F= '/^total_files=/{print $2}' "$STATE_DIR/common/chunks/chunks.meta" 2>/dev/null)
            check "$job: published chunk set identical to a solo run, meta total correct (meta=${META_TOTAL:-?})" \
                'cat "$STATE_DIR"/common/chunks/chunk-*.txt | sort | cmp -s - "$T/c.base" && [ "${META_TOTAL:-x}" = "$(wc -l < "$T/c.base" | tr -d " ")" ]'
        fi
    done
    # A dead holder: heartbeat 20 minutes old.
    mkdir -p "$STATE_DIR/locks/chunks.lock"
    printf 'run_id=dead-pod\n' > "$STATE_DIR/locks/chunks.lock/owner"
    touch -d "@$(( $(date +%s) - 1200 ))" "$STATE_DIR/locks/chunks.lock/heartbeat" "$STATE_DIR/locks/chunks.lock"
    "$S/generate-chunks.sh" > "$T/stale.log" 2>&1; RC=$?
    check "stale lock (heartbeat 20 min old) is broken and the run proceeds (rc=$RC)" '[ "$RC" -eq 0 ] && grep -q "stale" "$T/stale.log"'
    unset SOURCE_PATH STATE_DIR REGISTRY_FILE CHUNK_COUNT
fi

# ================================================================ signal
# Start the container command under tini as PID 1 of a fresh PID namespace, wait until rsync is
# mid-file, SIGTERM PID 1 (what kubelet does), and inspect the target.
sigterm_run() {  # sigterm_run <label> <dst> <logfile> <tini flags> -- command...
    local label="$1" dst="$2" log="$3" tf="$4"; shift 5
    unshare --pid --fork --mount-proc tini $tf -- "$@" > "$log" 2>&1 &
    local u=$! i tpid
    for i in $(seq 1 900); do
        find "$dst" -name '.blob*' -type f 2>/dev/null | grep -q . && break; sleep 0.1
    done
    sleep 1
    tpid=$(pgrep -P "$u" -x tini)
    [ -n "$tpid" ] && kill -TERM "$tpid"
    for i in $(seq 1 600); do kill -0 "$u" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$u" 2>/dev/null && { kill -KILL "$u"; echo "(killed after 60s)" >> "$log"; }
    local orphans partials
    orphans=$(find "$dst" -name '.blob*' -type f ! -path '*/.rsync-partial/*' | wc -l)
    partials=$(find "$dst" -path '*/.rsync-partial/*' -type f | wc -l)
    check "$label: no orphan .<file>.XXXXXX temp file left in the target (found $orphans)" '[ "$orphans" -eq 0 ]'
    check "$label: interrupted file kept in .rsync-partial/ (found $partials)" '[ "$partials" -ge 1 ]'
    check "$label: status file records the interruption" 'grep -q "interrupted=TERM" "$dst/.nas-sync-status/last-run" 2>/dev/null'
}

if want signal; then
    head2 "signal — SIGTERM to PID 1 on the CronJob path (§8.5, §8.6, mode scripts)"
    fresh_src
    mkdir -p "$T/src/big" "$T/src/big2"
    head -c 40000000 /dev/urandom > "$T/src/big/blob.bin"; head -c 40000000 /dev/urandom > "$T/src/big2/blob2.bin"
    shim_set 4000                                                         # ~4 MB/s → ~10 s per file
    for tf in "-g" ""; do
        for mode in standard parallel; do
            DST=$(fresh_dst "sig-${mode}${tf}")
            PATH="$T/shim:$PATH" SYNC_MODE=$mode LOCAL_NAS_PATH="$DST" PARALLEL_WORKERS=2 ISTIO_ADMIN_PORT=1 \
                sigterm_run "tini ${tf:-(no -g)} $mode" "$DST" "$T/sig-$mode$tf.log" "$tf" -- "$S/run-with-sidecar-quit.sh"
        done
    done
    shim_off
fi

# ================================================================ deploy (--slow)
if [ "$SLOW" -eq 1 ] && want deploy; then
    head2 "deploy — SIGTERM to the Deployment entrypoint (§8.7)"
    if ! command -v cron >/dev/null 2>&1; then
        skip "cron not installed"
    elif pgrep -x cron >/dev/null 2>&1; then
        skip "a cron daemon is already running here — it would also execute /etc/cron.d/nas-sync"
    else
        install -m 0755 "$T/shim/rsync" /usr/local/bin/rsync              # cron's PATH finds the shim first
        shim_set 4000
        # (a) during the initial sync
        fresh_src; mkdir -p "$T/src/big"; head -c 40000000 /dev/urandom > "$T/src/big/blob.bin"
        DST=$(fresh_dst dep-initial)
        SYNC_MODE=standard LOCAL_NAS_PATH="$DST" CRON_SCHEDULE='* * * * *' \
            sigterm_run "Deployment, initial sync" "$DST" "$T/dep-initial.log" "-g" -- "$S/entrypoint-deployment.sh"
        # (b) during a cron-launched run: quick initial sync, then a big file for the cron run
        fresh_src; echo tiny > "$T/src/tiny.txt"
        DST=$(fresh_dst dep-cron)
        ( for _ in $(seq 1 300); do grep -q 'Initial sync done' "$T/dep-cron.log" 2>/dev/null && break; sleep 0.2; done
          mkdir -p "$T/src/big"; head -c 40000000 /dev/urandom > "$T/src/big/blob.bin" ) &
        SYNC_MODE=standard LOCAL_NAS_PATH="$DST" CRON_SCHEDULE='* * * * *' \
            sigterm_run "Deployment, cron-launched run" "$DST" "$T/dep-cron.log" "-g" -- "$S/entrypoint-deployment.sh"
        # The cron daemon lived inside the PID namespace and died with its PID 1.
        shim_off; rm -f /usr/local/bin/rsync /etc/cron.d/nas-sync
    fi
fi

printf '\n'
[ "$SKIP" -gt 0 ] && printf '%d skipped. ' "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31m%d check(s) FAILED\033[0m, %d passed\n' "$FAIL" "$PASS"
    exit 1
fi
printf '\033[32mAll %d checks passed\033[0m\n' "$PASS"
exit 0
````

- [ ] **Step 2: Make it executable and syntax-check it**

```bash
chmod +x scripts/test-guide-behavior.sh && bash -n scripts/test-guide-behavior.sh && echo OK
```

Expected:

```text
OK
```


- [ ] **Step 3: Run it against v3.15 — every case must fail**

```bash
bash scripts/test-guide-behavior.sh --native cross-cluster-rsync-guide-v3.15-consolidated.md | tail -1
```

Expected:

```text
25 check(s) FAILED, 6 passed
```

The 6 passes are sanity checks, such as "generation 1 published" and "top-level loose file is synced". Every case has at least one FAIL.

- [ ] **Step 4: Run it against the v3.16 file — identical result (content is still v3.15)**

```bash
bash scripts/test-guide-behavior.sh --native cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
25 check(s) FAILED, 6 passed
```


- [ ] **Step 5: Check the docker path once (if docker is available)**

```bash
bash scripts/test-guide-behavior.sh --case loose cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
2 check(s) FAILED, 2 passed
```

This mode was **not** exercised while writing the plan (no docker in that environment). If it fails for reasons unrelated to the guide (apt mirror, `--privileged` refused), record the error in the commit message. Then keep using `--native` inside a disposable container.

- [ ] **Step 6: Commit**

```bash
git add scripts/test-guide-behavior.sh
git commit -m "test: add runtime behavior suite for the guide scripts (red on v3.15)"
```

---
### Task 3: Client library (§8.11) and parallel mode (§8.3)

Fixes F4 (folder names), F5 (recursive top-level pass) and F1's client side (generation check). It also brings in the SIGTERM helpers that later tasks use.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.16-consolidated.md`, in §8.3 (block), §8.8, §8.9 and §14. A new §8.11 section goes after §8.10.

**Interfaces:**
- Produces (§8.11, sourced as `. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh"`):
  - `list_top_dirs`: writes NUL-terminated top-level dir names to stdout and returns rsync's rc. It needs `REMOTE_URL`, `RSYNC_PASSWORD_FILE`, `EXCLUDE_FILE` and `log()`. It applies `EXCLUDE_FILE` to the listing.
  - `wait_child <pid>`: sets `WAIT_RC` to the child's real exit status, even across trap interrupts.
  - `term_trap_install`: sets `trap 'TERMINATING=1' TERM INT`.
  - `check_term`: when `TERMINATING` is set, logs and does `exit 143`.
- §8.3:
  - New env `CHUNK_RETRY_WAIT` (default 30).
  - It accepts `chunks.meta` keys `generated_at`, `generation`, `chunk_count` and `total_files`, and chunk files named `chunk-<generation>-NNN.txt`.
  - Without a `generation` line it falls back to the v3.15 `chunk-*.txt` rule, with a WARN.

- [ ] **Step 1: Run the failing cases**

```bash
bash scripts/test-guide-behavior.sh --native --case loose --case names cross-cluster-rsync-guide-v3.16-consolidated.md | grep -E 'FAIL|passed'
```

Expected:

```text
  FAIL sync machinery (.nas-sync-state) is not replicated
  FAIL excluded top-level dir (.git) is not replicated
  FAIL verify tier 2 on an in-sync tree: exit 0, drift=0 (rc=1)
  FAIL verify tier 2 detects silent corruption in '資料', 'My folder', 'a[1]' (drift=2, rc=1)
  FAIL top-level pass does NOT recurse (v3.15: -a implied -r → full serial sync)
  FAIL workers that never ran are detected — not 'all OK' (rc=0)
6 check(s) FAILED, 5 passed
```

- [ ] **Step 2: Insert §8.11 after §8.10 (before Step 6A)** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
> they agree by default — if you diverge them, raise `VERIFY_FAIL_THRESHOLD` accordingly.

---

## 9. Step 6A — Cluster A: CronJob Deployment
```

Replace with:

````text
> they agree by default — if you diverge them, raise `VERIFY_FAIL_THRESHOLD` accordingly.

### 8.11 File: `cluster-a/scripts/nas-sync-lib.sh` (v3.16)

> Write this file **before** running §8.9 — it is in the Dockerfile's COPY list (§8.8), and
> every client script sources it. Section order is kept stable; build order is §8.10, §8.11,
> then §8.9.
>
> Holds only the helpers v3.16 introduced: a top-level folder lister that survives any
> character in a name (§8.3 fallback, §8.10 tier 2), and the pieces of graceful shutdown.

```bash
#!/bin/bash
#############################################
# NAS Sync client library — v3.16
# Sourced by every client script. Holds ONLY
# the helpers v3.16 introduced:
#   list_top_dirs      top-level dir names, NUL-terminated
#   wait_child         wait that survives trap interrupts
#   term_trap_install  on SIGTERM: let rsync finish, then stop
#   check_term         exit 143 once SIGTERM has arrived
# Caller provides: log(); for list_top_dirs also
# REMOTE_URL, RSYNC_PASSWORD_FILE, EXCLUDE_FILE.
#############################################

# Top-level directory names of the remote module, each terminated by NUL, on stdout.
# Returns rsync's rc. Why not `awk '{print $NF}'` (v3.15): it cut names at the last space;
# --list-only escapes non-ASCII bytes as \#ooo unless -8 is given; and any name passed as
# part of a REMOTE PATH is glob-expanded by the daemon ("a[1]/" is served from "a1").
# Callers must therefore transfer these names with --files-from --from0, never in a path.
# The same exclude file as the sync is applied here, so .nas-sync-state/ and friends are
# filtered with identical semantics (names given explicitly to --files-from bypass excludes).
list_top_dirs() {
    local out rc
    local args=(--list-only -8 --password-file="$RSYNC_PASSWORD_FILE")
    [ -f "$EXCLUDE_FILE" ] && args+=(--exclude-from="$EXCLUDE_FILE")
    out=$(mktemp) || return 1
    rsync "${args[@]}" "${REMOTE_URL}/" > "$out"
    rc=$?
    # Line format: perms, size, YYYY/MM/DD, HH:MM:SS, name. The name is everything after
    # the time, so spaces, leading spaces and tabs survive. MOTD lines never match.
    # -8 still escapes control characters (a newline in a name is \#012): decode only
    # \#ooo — printf %b would also turn a literal "\n" inside a name into a newline.
    sed -n 's/^d[^ ]* \{1,\}[0-9,.]\{1,\} [0-9]\{4\}\/[0-9]\{2\}\/[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //p' "$out" \
        | grep -vx '\.' \
        | perl -ne 'chomp; s/\\#([0-7]{3})/chr(oct($1))/ge; print "$_\0"'
    rm -f "$out"
    return "$rc"
}

# wait_child <pid>: sets WAIT_RC to the child's real exit status. A trapped signal makes
# `wait` return early (>128) while the child is still running — keep waiting until it is
# gone. A shell that exits before its children unwinds the chain up to tini (PID 1), and
# the kernel then SIGKILLs rsync before it can save its partial file.
wait_child() {
    local r
    while :; do
        wait "$1"; r=$?
        [ "$r" -le 128 ] && { WAIT_RC=$r; return; }
        kill -0 "$1" 2>/dev/null || { WAIT_RC=$r; return; }
    done
}

# Mode scripts: on SIGTERM only set a flag. bash runs the trap AFTER the foreground rsync
# exits, so rsync (which receives SIGTERM itself) moves its partial file into
# .rsync-partial/ first. check_term then stops before the next step.
TERMINATING=""
term_trap_install() { trap 'TERMINATING=1' TERM INT; }
check_term() {
    [ -n "$TERMINATING" ] || return 0
    log "Interrupted (SIGTERM) — stopping after the current step"
    exit 143
}
```

> **Shutdown model (v3.16).** One place sends SIGTERM; every shell that has children waits
> for them. The CronJob wrapper (§8.6) signals its own process group; the Deployment
> entrypoint (§8.7) signals each run's process group (cron gives every job its own session).
> The dispatcher (§8.5) and the mode scripts only wait, so rsync — which handles SIGTERM
> itself — moves its partial file into `.rsync-partial/` before anything exits, and the status
> file records `interrupted=TERM`. In v3.15 the wrapper died first, tini (PID 1) exited, and
> the kernel SIGKILLed rsync, leaving a `.<name>.XXXXXX` temp file in the target tree that no
> later run removes — the sync runs without --delete.

---

## 9. Step 6A — Cluster A: CronJob Deployment
````

- [ ] **Step 3: Replace the §8.3 script block** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Replace the entire contents of the first ```` ```bash ```` block under the heading `### 8.3 File:` (keep the fences) with:

```bash
#!/bin/bash
#############################################
# NAS Sync — PARALLEL mode (v3.16)
# Preferred: N workers over server-generated
#   equal-count chunk lists (§4.6 / §6.3)
# Fallback:  N workers split by top-level folder
#   when chunks are missing, stale or not one
#   consistent generation — a failed chunk job
#   never blocks a run.
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
PARALLEL_WORKERS="${PARALLEL_WORKERS:-6}"
PREFLIGHT_RETRIES="${PREFLIGHT_RETRIES:-10}"
PREFLIGHT_WAIT="${PREFLIGHT_WAIT:-6}"
# Chunks older than this are ignored (fall back to top-level split).
# Chunk CronJob runs weekly ~2h before the reconcile, so 24h is ample headroom.
CHUNK_MAX_AGE="${CHUNK_MAX_AGE:-86400}"
CHUNKS_REMOTE="${CHUNKS_REMOTE:-.nas-sync-state/common/chunks}"
# v3.16: a fetch that overlaps the server's swap fails with rc 24 (§4.6). Wait, refetch once.
CHUNK_RETRY_WAIT="${CHUNK_RETRY_WAIT:-30}"

WORK_DIR="/tmp/nas-sync-parallel.$$"
NAMES_BIN="${WORK_DIR}/names.bin"      # top-level names, NUL-terminated
FOLDER_LIST="${WORK_DIR}/folders.bin"  # "index\0name\0" pairs for the workers
CHUNK_DIR="${WORK_DIR}/chunks"
RC_DIR="${WORK_DIR}/rc"                # one rc file per unit — nothing else in here
NAME_DIR="${WORK_DIR}/names"           # folder name per index, for the failure report
REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

# v3.16: shared helpers (§8.11). On SIGTERM, let rsync save its partial, then stop.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh" || die "nas-sync-lib.sh not found (§8.11)"
term_trap_install

# rsync 23/24 are normal on a live source — see §8.2.
rsync_rc_ok() {
    case "$1" in
        0)  return 0 ;;
        24) return 0 ;;
        23) return 0 ;;
        *)  return 1 ;;
    esac
}
export -f rsync_rc_ok

wait_for_remote() {
    local i=1
    while [ "$i" -le "$PREFLIGHT_RETRIES" ]; do
        nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null && return 0
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES}) — sidecar may still be starting"
        sleep "$PREFLIGHT_WAIT"
        check_term
        i=$((i+1))
    done
    return 1
}

# --partial-dir: keep interrupted transfers out of the visible tree (§8.2).
RSYNC_FLAGS="-a --whole-file --partial --partial-dir=.rsync-partial --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$CHUNK_DIR" "$RC_DIR" "$NAME_DIR" || die "Cannot create $WORK_DIR"

START=$(date +%s)
log "=== NAS SYNC (parallel, $PARALLEL_WORKERS workers) ==="

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
wait_for_remote || die "Remote not reachable after ${PREFLIGHT_RETRIES} attempts"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

export REMOTE_URL LOCAL_NAS_PATH RSYNC_FLAGS CHUNK_DIR RC_DIR NAME_DIR

# ---- Worker: one server-generated chunk list ----
sync_one_chunk() {
    local chunk="$1"
    local name; name=$(basename "$chunk")
    local s; s=$(date +%s)
    echo "$(date '+%H:%M:%S') [worker] START $name ($(wc -l < "$chunk" | tr -d ' ') files)"
    rsync $RSYNC_FLAGS --files-from="$chunk" "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1 | sed "s/^/[$name] /"
    local rc=${PIPESTATUS[0]}
    echo "$rc" > "${RC_DIR}/${name}"
    echo "$(date '+%H:%M:%S') [worker] DONE  $name (rc=$rc, $(( $(date +%s) - s ))s)"
}
export -f sync_one_chunk

# ---- Worker: one top-level folder (fallback path) ----
# v3.16: the name travels via --files-from --from0, never inside a remote path. The daemon
# glob-expands remote paths (a folder named "a[1]" was served from "a1"), and a name may hold
# spaces, quotes, CJK or a newline. -r is explicit: -a does not imply it under --files-from.
sync_one_folder() {
    local idx="$1" name="$2"
    local s; s=$(date +%s)
    printf '%s\0' "$name" > "${NAME_DIR}/folder-${idx}"
    echo "$(date '+%H:%M:%S') [worker] START folder#${idx} $(printf '%q' "$name")"
    printf '%s\0' "$name" \
        | rsync $RSYNC_FLAGS -r --from0 --files-from=- "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1 \
        | awk -v p="[folder#${idx}] " '{ print p $0; fflush() }'
    local rc=${PIPESTATUS[1]}
    echo "$rc" > "${RC_DIR}/folder-${idx}"
    echo "$(date '+%H:%M:%S') [worker] DONE  folder#${idx} (rc=$rc, $(( $(date +%s) - s ))s)"
}
export -f sync_one_folder

# ---- Try the chunked path (server-generated equal-count chunks, §4.6) ----
# v3.16: accept a fetched set only if it is ONE complete generation. The server names every
# file chunk-<generation>-NNN.txt, so a fetch that overlaps its swap fails (rc 24) instead
# of silently mixing two generations — a mixed set left ~22% of the tree unreconciled.
# Returns 0 = usable set, 1 = unusable (fall back), 2 = inconsistent (worth one retry).
fetch_chunks() {
    local rc meta="${CHUNK_DIR}/chunks.meta" gen_at count n_all
    rm -rf "$CHUNK_DIR"; mkdir -p "$CHUNK_DIR"
    rsync -a --password-file="$RSYNC_PASSWORD_FILE" \
        "${REMOTE_URL}/${CHUNKS_REMOTE}/" "${CHUNK_DIR}/" >/dev/null 2>&1
    rc=$?
    check_term
    if [ "$rc" -eq 24 ]; then
        CHUNK_REASON="Chunk files vanished mid-fetch (rc=24) — the server is publishing a new generation"
        return 2
    fi
    if [ "$rc" -ne 0 ] || [ ! -f "$meta" ]; then
        CHUNK_REASON="No chunk lists available (rc=$rc)"
        return 1
    fi
    gen_at=$(awk -F= '/^generated_at=/{print $2}' "$meta")
    case "$gen_at" in ''|*[!0-9]*) gen_at=0 ;; esac
    AGE=$(( $(date +%s) - gen_at ))
    if [ "$gen_at" -eq 0 ] || [ "$AGE" -gt "$CHUNK_MAX_AGE" ]; then
        CHUNK_REASON="Chunks are stale (age=${AGE}s > ${CHUNK_MAX_AGE}s)"
        return 1
    fi
    CHUNK_GEN=$(awk -F= '/^generation=/{print $2}' "$meta")
    count=$(awk -F= '/^chunk_count=/{print $2}' "$meta")
    TOTAL_FILES=$(awk -F= '/^total_files=/{print $2}' "$meta")
    n_all=$(find "$CHUNK_DIR" -maxdepth 1 -name 'chunk-*.txt' | wc -l | tr -d ' ')
    if [ -z "$CHUNK_GEN" ]; then
        # Only after a rollback to a v3.15 server: same acceptance rule as v3.15.
        log "WARN: chunks.meta has no generation (v3.15 server) — cannot prove the set is one generation"
        CHUNK_GLOB='chunk-*.txt'
        NCHUNK=$n_all
    else
        CHUNK_GLOB="chunk-${CHUNK_GEN}-*.txt"
        NCHUNK=$(find "$CHUNK_DIR" -maxdepth 1 -name "$CHUNK_GLOB" | wc -l | tr -d ' ')
        if [ "$NCHUNK" != "$count" ] || [ "$n_all" != "$NCHUNK" ]; then
            CHUNK_REASON="Chunk set inconsistent (generation ${CHUNK_GEN}: ${NCHUNK} of ${count:-?} chunks, ${n_all} chunk files in total)"
            return 2
        fi
    fi
    if [ "$NCHUNK" -eq 0 ]; then
        CHUNK_REASON="chunks.meta present but no chunk files"
        return 1
    fi
    return 0
}

USE_CHUNKS=false
log "Fetching chunk lists from ${CHUNKS_REMOTE}/ ..."
fetch_chunks; CS=$?
if [ "$CS" -eq 2 ]; then
    log "$CHUNK_REASON — retrying once in ${CHUNK_RETRY_WAIT}s"
    sleep "$CHUNK_RETRY_WAIT"
    check_term
    fetch_chunks; CS=$?
fi
if [ "$CS" -eq 0 ]; then
    USE_CHUNKS=true
    log "Using $NCHUNK server-generated chunks (generation=${CHUNK_GEN:-none}, age=${AGE}s, ${TOTAL_FILES:-?} files total)"
else
    log "$CHUNK_REASON — falling back to top-level split"
fi

if [ "$USE_CHUNKS" = true ]; then
    UNIT="chunks"
    UNIT_COUNT="$NCHUNK"
    EXPECTED_RC="$NCHUNK"
    # xargs ignores SIGTERM so it waits for every worker; each rsync still handles SIGTERM
    # itself and saves its partial (§8.11). -0 so no character in a path is special.
    find "$CHUNK_DIR" -maxdepth 1 -name "$CHUNK_GLOB" -print0 | sort -z \
        | ( trap '' TERM; exec xargs -0 -n 1 -P "$PARALLEL_WORKERS" bash -c 'sync_one_chunk "$1"' _ )
    XARGS_RC=${PIPESTATUS[2]}
else
    UNIT="folders"
    log "Listing top-level folders..."
    list_top_dirs > "$NAMES_BIN"
    LIST_RC=$?
    check_term
    [ "$LIST_RC" -eq 0 ] || die "Cannot list top-level folders (rsync rc=$LIST_RC)"
    UNIT_COUNT=$(tr -cd '\0' < "$NAMES_BIN" | wc -c | tr -d ' ')
    log "Found $UNIT_COUNT top-level folders"
    [ "$UNIT_COUNT" -gt 0 ] || die "No folders found"

    # v3.16: --no-recursive. -a implies -r, so v3.15's "-a --dirs" copied the WHOLE tree here,
    # serially, before any worker started. This pass owns the top level only: loose files,
    # symlinks, and the top-level directories themselves (empty; workers fill them).
    log "Syncing top-level loose files..."
    rsync $RSYNC_FLAGS --no-recursive --dirs "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1 | grep -v '^$'
    echo "${PIPESTATUS[0]}" > "${RC_DIR}/loose"
    check_term
    EXPECTED_RC=$(( UNIT_COUNT + 1 ))

    i=0
    while IFS= read -r -d '' n; do
        i=$((i+1))
        printf '%s\0%s\0' "$i" "$n"
    done < "$NAMES_BIN" > "$FOLDER_LIST"
    ( trap '' TERM; exec xargs -0 -n 2 -P "$PARALLEL_WORKERS" bash -c 'sync_one_folder "$1" "$2"' _ ) < "$FOLDER_LIST"
    XARGS_RC=$?
fi

# ---- Tally worker results: one bad worker must not hide the others ----
FAILED=""
FAIL_COUNT=0
RC_COUNT=0
for f in "${RC_DIR}"/*; do
    [ -f "$f" ] || continue
    RC_COUNT=$((RC_COUNT+1))
    rc=$(cat "$f")
    if ! rsync_rc_ok "$rc"; then
        u=$(basename "$f")
        if [ -f "${NAME_DIR}/$u" ]; then
            IFS= read -r -d '' n < "${NAME_DIR}/$u"
            u="$u=$(printf '%q' "$n")"
        fi
        FAILED="$FAILED ${u}(rc=$rc)"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
done
# v3.16: prove every unit ran. v3.15 trusted the rc files alone, so an xargs that stopped
# early (it did, on a folder name containing a quote) still ended "all OK".
if [ "$XARGS_RC" -ne 0 ]; then
    FAILED="$FAILED xargs(rc=$XARGS_RC)"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi
if [ "$RC_COUNT" -ne "$EXPECTED_RC" ]; then
    FAILED="$FAILED only-${RC_COUNT}-of-${EXPECTED_RC}-units-reported"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi

check_term

DUR=$(( $(date +%s) - START ))
if [ "$FAIL_COUNT" -gt 0 ]; then
    log_error "$FAIL_COUNT problem(s) across $UNIT_COUNT $UNIT:$FAILED"
    log "=== COMPLETE: $UNIT_COUNT $UNIT, ${DUR}s, FAILED=$FAIL_COUNT ==="
    exit 1
fi

log "=== COMPLETE: $UNIT_COUNT $UNIT, ${DUR}s, all OK ==="
exit 0
```

- [ ] **Step 4: §8.8: perl in the tool check** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
    && command -v flock && command -v cksum
```

Replace with:

```text
    && command -v flock && command -v cksum \
    && command -v perl
```

- [ ] **Step 5: §8.8: perl comment** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
# and cksum (coreutils) — the verify slice hash (§8.10).
```

Replace with:

```text
# and cksum (coreutils) — the verify slice hash (§8.10).
# v3.16 adds perl (perl-base, Essential in ubuntu:24.04) — the folder-name decoder (§8.11).
```

- [ ] **Step 6: §8.8: COPY the library** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
COPY entrypoint-deployment.sh   /userapp/scripts/
```

Replace with:

```text
COPY entrypoint-deployment.sh   /userapp/scripts/
COPY nas-sync-lib.sh            /userapp/scripts/
```

- [ ] **Step 7: §8.9: sanity check includes perl** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
which curl wget nc bash tini xargs flock && echo OK
```

Replace with:

```text
which curl wget nc bash tini xargs flock perl && echo OK
```

- [ ] **Step 8: §14: list nas-sync-lib.sh** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
    └── entrypoint-deployment.sh   # 8.7  (Deployment entry)
```

Replace with:

```text
    ├── entrypoint-deployment.sh   # 8.7  (Deployment entry)
    └── nas-sync-lib.sh            # 8.11 (v3.16, shared helpers — sourced by every script)
```

- [ ] **Step 9: Run the checker**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md
```

Expected:

```text
All checks passed (0 warning(s))
```


- [ ] **Step 10: Run the cases — everything passes except one verify check, which Task 4 fixes**

```bash
bash scripts/test-guide-behavior.sh --native --case loose --case names cross-cluster-rsync-guide-v3.16-consolidated.md | tail -2
```

Expected:

```text
  FAIL verify tier 2 on an in-sync tree: exit 0, drift=0 (rc=1)
1 check(s) FAILED, 10 passed
```


- [ ] **Step 11: Commit**

```bash
git add cross-cluster-rsync-guide-v3.16-consolidated.md
git commit -m "v3.16: nas-sync-lib.sh (§8.11); parallel mode: any-character folder names, non-recursive top-level pass, generation-checked chunks"
```

---
### Task 4: Verify tier 2 sees every folder (§8.10)

Fixes F3.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.16-consolidated.md`, in §8.10.
- Modify: `docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md`, one line in §5.3.

**Interfaces:**
- Consumes: `list_top_dirs`, `term_trap_install` and `check_term` from Task 3.

- [ ] **Step 1: Run the failing case**

```bash
bash scripts/test-guide-behavior.sh --native --case names cross-cluster-rsync-guide-v3.16-consolidated.md | tail -2
```

Expected:

```text
  FAIL verify tier 2 on an in-sync tree: exit 0, drift=0 (rc=1)
1 check(s) FAILED, 6 passed
```

- [ ] **Step 2: §8.10: header version** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
# NAS Sync — VERIFY mode (v3.15)
```

Replace with:

```text
# NAS Sync — VERIFY mode (v3.16)
```

- [ ] **Step 3: §8.10: source the library** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
die() { log_error "$1"; exit "${2:-1}"; }

wait_for_remote() {
    local i=1
    while [ "$i" -le "$PREFLIGHT_RETRIES" ]; do
        nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null && return 0
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES})"
        sleep "$PREFLIGHT_WAIT"
        i=$((i+1))
```

Replace with:

```text
die() { log_error "$1"; exit "${2:-1}"; }

# v3.16: shared helpers (§8.11). On SIGTERM, let rsync finish, then stop.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh" || die "nas-sync-lib.sh not found (§8.11)"
term_trap_install

wait_for_remote() {
    local i=1
    while [ "$i" -le "$PREFLIGHT_RETRIES" ]; do
        nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null && return 0
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES})"
        sleep "$PREFLIGHT_WAIT"
        check_term
        i=$((i+1))
```

- [ ] **Step 4: §8.10: stop after tier 1 on SIGTERM** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
    rsync $BASE_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" > "${WORK_DIR}/meta.out" 2>"${WORK_DIR}/meta.err"
    RC=$?
```

Replace with:

```text
    rsync $BASE_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" > "${WORK_DIR}/meta.out" 2>"${WORK_DIR}/meta.err"
    RC=$?
    check_term
```

- [ ] **Step 5: §8.10: tier 2 — list, slice and check by NUL-safe names** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
    rsync --list-only --password-file="$RSYNC_PASSWORD_FILE" "${REMOTE_URL}/" 2>/dev/null \
        | awk '$1 ~ /^d/ && $NF != "." {print $NF}' > "${WORK_DIR}/topdirs.txt"

    : > "${WORK_DIR}/slice.txt"
    while read -r d; do
        [ -n "$d" ] || continue
        H=$(printf '%s' "$d" | cksum | cut -d' ' -f1)
        [ $(( H % VERIFY_SLICES )) -eq "$SLICE" ] && printf '%s\n' "$d" >> "${WORK_DIR}/slice.txt"
    done < "${WORK_DIR}/topdirs.txt"

    SLICE_N=$(wc -l < "${WORK_DIR}/slice.txt" | tr -d ' ')
    log "Tier 2: $SLICE_N of $(wc -l < "${WORK_DIR}/topdirs.txt" | tr -d ' ') top-level dirs in this slice"

    CK_DRIFT=0; CK_CHECKED=0
    while read -r d; do
        [ -n "$d" ] || continue
        rsync $BASE_FLAGS --checksum "${REMOTE_URL}/${d}/" "${LOCAL_NAS_PATH}/${d}/" \
            > "${WORK_DIR}/ck.out" 2>/dev/null
        n=$(count_drift "${WORK_DIR}/ck.out")
        c=$(wc -l < "${WORK_DIR}/ck.out" | tr -d ' ')
        [ "$n" -gt 0 ] && log "  drift in $d: $n"
        CK_DRIFT=$(( CK_DRIFT + n ))
        CK_CHECKED=$(( CK_CHECKED + c ))
    done < "${WORK_DIR}/slice.txt"
```

Replace with:

```text
    # v3.16: same top-level list as the parallel fallback (§8.11). v3.15's awk cut names at
    # spaces and could not read escaped CJK names, so those dirs were never byte-checked.
    list_top_dirs > "${WORK_DIR}/topdirs.bin"
    LIST_RC=$?
    check_term
    [ "$LIST_RC" -eq 0 ] || die "Tier 2: cannot list top-level dirs (rsync rc=$LIST_RC)" "$LIST_RC"

    : > "${WORK_DIR}/slice.bin"
    NTOP=0
    while IFS= read -r -d '' d; do
        NTOP=$((NTOP+1))
        H=$(printf '%s' "$d" | cksum | cut -d' ' -f1)
        [ $(( H % VERIFY_SLICES )) -eq "$SLICE" ] && printf '%s\0' "$d" >> "${WORK_DIR}/slice.bin"
    done < "${WORK_DIR}/topdirs.bin"

    SLICE_N=$(tr -cd '\0' < "${WORK_DIR}/slice.bin" | wc -c | tr -d ' ')
    log "Tier 2: $SLICE_N of $NTOP top-level dirs in this slice"

    CK_DRIFT=0; CK_CHECKED=0
    while IFS= read -r -d '' d; do
        # v3.16: the name goes through --files-from --from0, never into a remote path (the
        # daemon glob-expands paths: "a[1]" was compared against "a1"). Errors are no longer
        # discarded — a check that silently compares nothing is worse than a failed one.
        printf '%s\0' "$d" \
            | rsync $BASE_FLAGS --checksum -r --from0 --files-from=- "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" \
                > "${WORK_DIR}/ck.out" 2> "${WORK_DIR}/ck.err"
        RC=${PIPESTATUS[1]}
        check_term
        case "$RC" in
            0|24) ;;
            23)   log "WARN: rc=23 checking $(printf '%q' "$d") (usually: removed between listing and checking): $(head -1 "${WORK_DIR}/ck.err")" ;;
            *)    log_error "rsync failed checking $(printf '%q' "$d") (rc=$RC)"
                  sed -n '1,20p' "${WORK_DIR}/ck.err" >&2
                  die "verify aborted" "$RC" ;;
        esac
        n=$(count_drift "${WORK_DIR}/ck.out")
        c=$(wc -l < "${WORK_DIR}/ck.out" | tr -d ' ')
        [ "$n" -gt 0 ] && log "  drift in $(printf '%q' "$d"): $n"
        CK_DRIFT=$(( CK_DRIFT + n ))
        CK_CHECKED=$(( CK_CHECKED + c ))
    done < "${WORK_DIR}/slice.bin"
```

- [ ] **Step 6: Spec §5.3: rc 23 wording matches the implementation** — `docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md`

Find (occurs exactly once):

```text
  - rc 23 containing `change_dir … failed` is logged as a WARN, because the directory vanished between listing and
    checking.
```

Replace with:

```text
  - rc 23 is logged as a WARN with the first stderr line; it usually means the directory was removed between
    listing and checking.
```

- [ ] **Step 7: Run the checker and the names case**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md
bash scripts/test-guide-behavior.sh --native --case names cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
All checks passed (0 warning(s))
All 7 checks passed
```


- [ ] **Step 8: Commit**

```bash
git add cross-cluster-rsync-guide-v3.16-consolidated.md docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md
git commit -m "v3.16: verify tier 2 lists folders via list_top_dirs and checks them via --files-from; rsync errors fail the run"
```

---
### Task 5: Cluster B — generator lock (§4.7) and generation-named chunks (§4.3, §4.6)

Fixes F2 (overlapping runs of the same generator) and F1's server side (mixed chunk set).

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.16-consolidated.md`:
  - §4.3 and §4.6: block replaced, plus a note.
  - §4.4, §4.5, §6.1, §6.3 and §14.
  - New §4.7 section after §4.6.

**Interfaces:**
- Produces (§4.7, sourced as `. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-state-lock.sh"`, requires `STATE_DIR` and `log()`):
  - `lock_acquire <manifests|chunks>`: returns 0 while holding the lock. If the lock is held, it **exits 75**. If the locks dir can't be created, it exits 1.
  - `lock_release`: installed as the EXIT trap.
  - Lock layout: `$STATE_DIR/locks/<name>.lock/{owner,heartbeat}`.
  - Env: `LOCK_HEARTBEAT` (60) and `LOCK_STALE` (600).
- §4.6:
  - publishes `chunk-g<epoch>-NNN.txt`;
  - `chunks.meta` gains `generation=g<epoch>`;
  - temp dirs are `.chunks.tmp.<RUN_ID>` and `.chunks.old.<RUN_ID>`, where `RUN_ID=<hostname>-<pid>-<epoch>`.
- §4.3: temp files are `sync-manifest.txt.tmp.<RUN_ID>` and `manifest.meta.tmp.<RUN_ID>`; a failed publish now exits 1.

- [ ] **Step 1: Run the failing cases**

```bash
bash scripts/test-guide-behavior.sh --native --case lock --case swap cross-cluster-rsync-guide-v3.16-consolidated.md | grep -E 'FAIL|passed'
```

Expected:

```text
  FAIL reconcile covers every path despite the mid-fetch swap (missing=5839, rc=0)
  FAIL client never accepted a mixed set (retried or used one generation)
  FAIL manifests: overlapping second run exits 75, first succeeds (rcA=0 rcB=0)
  FAIL manifests: published manifest identical to a solo run
  FAIL chunks: overlapping second run exits 75, first succeeds (rcA=0 rcB=1)
  FAIL chunks: published chunk set identical to a solo run, meta total correct (meta=11778)
  FAIL stale lock (heartbeat 20 min old) is broken and the run proceeds (rc=0)
7 check(s) FAILED, 1 passed
```

`missing=` and `meta=` depend on timing; what matters is that every lock and swap check FAILs.

- [ ] **Step 2: Insert §4.7 after §4.6 (before Step 2)** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
> `rm -rf /mnt/nas-source/.nas-sync-state/common/chunks` from a server pod.

---

## 5. Step 2 — Cluster B: Deploy rsync Server
```

Replace with:

````text
> `rm -rf /mnt/nas-source/.nas-sync-state/common/chunks` from a server pod.

### 4.7 File: `cluster-b/scripts/nas-sync-state-lock.sh` (v3.16)

> Write this file **before** running §4.5 — it is in the Dockerfile's COPY and CRLF-guard
> lists (§4.4). Section order is kept stable; build order is §4.6, §4.7, then §4.5.
>
> Sourced by both generators (§4.3, §4.6). `concurrencyPolicy: Forbid` stops the CronJob
> controller from starting a second *scheduled* run, but it is not a lock: a manual
> `kubectl create job --from=cronjob/…` (the runbook uses these in S1, S2, S4 and S9) or a
> replacement pod still overlaps the scheduled one, and two overlapping generators tear the
> manifest and publish a half-written chunk set. With this library the second run exits
> **75** without touching anything and logs who holds the lock.

```bash
#!/bin/bash
#############################################
# State-dir lock library (Cluster B) — v3.16
# Sourced by generate-manifests.sh (§4.3) and
# generate-chunks.sh (§4.6). One lock per job.
#
# concurrencyPolicy: Forbid is NOT a lock. A
# `kubectl create job --from=cronjob/…` run (the
# runbook uses these), or a replacement pod,
# overlaps the scheduled run. Two overlapping
# generators tear the manifest and publish a
# half-written chunk set.
#
# mkdir is atomic on every NFS version. flock is
# NOT used: the pods run on different nodes, and
# on a `nolock` NFS mount flock is silently local.
#
# Caller provides: STATE_DIR, log(). Do not set
# your own EXIT trap after lock_acquire — it owns
# EXIT to release the lock.
#############################################

LOCK_HEARTBEAT="${LOCK_HEARTBEAT:-60}"   # seconds between heartbeat touches
LOCK_STALE="${LOCK_STALE:-600}"          # a heartbeat older than this = holder is dead
LOCK_EXIT_HELD=75                        # EX_TEMPFAIL: "another run holds the lock"
LOCK_RUN_ID="${RUN_ID:-${HOSTNAME:-unknown}-$$-$(date +%s)}"
LOCK_PATH=""
LOCK_HB_PID=""

# "Now" by the NAS clock. Pod clocks are never compared with NAS mtimes: touch a probe
# in the same directory and read its mtime back.
_lock_nas_now() {
    local probe="${STATE_DIR}/locks/.probe.${LOCK_RUN_ID}" t
    touch "$probe" 2>/dev/null || return 1
    t=$(stat -c %Y "$probe" 2>/dev/null)
    rm -f "$probe"
    [ -n "$t" ] && echo "$t"
}

# Seconds since the lock's last heartbeat (its dir mtime if the heartbeat file is missing).
_lock_age() {
    local now hb
    now=$(_lock_nas_now) || { echo 999999999; return; }
    hb=$(stat -c %Y "$1/heartbeat" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || { echo 999999999; return; }
    echo $(( now - hb ))
}

lock_release() {
    [ -n "$LOCK_HB_PID" ] && kill "$LOCK_HB_PID" 2>/dev/null
    [ -n "$LOCK_PATH" ] || return 0
    # Only remove the lock if it is still ours (it may have been broken as stale).
    grep -qx "run_id=${LOCK_RUN_ID}" "${LOCK_PATH}/owner" 2>/dev/null && rm -rf "$LOCK_PATH"
    return 0
}

# lock_acquire <name>: returns 0 holding the lock, or EXITS 75 (lock held) / 1 (cannot lock).
lock_acquire() {
    local name="$1" attempt age owner stale_dir
    mkdir -p "${STATE_DIR}/locks" || { log "ERROR: cannot create ${STATE_DIR}/locks (source NAS writable?)"; exit 1; }
    LOCK_PATH="${STATE_DIR}/locks/${name}.lock"
    for attempt in 1 2; do
        if mkdir "$LOCK_PATH" 2>/dev/null; then
            printf 'run_id=%s\nhost=%s\npid=%s\nstarted=%s\n' \
                "$LOCK_RUN_ID" "${HOSTNAME:-unknown}" "$$" "$(date +%s)" > "${LOCK_PATH}/owner"
            touch "${LOCK_PATH}/heartbeat"
            ( while sleep "$LOCK_HEARTBEAT"; do touch "${LOCK_PATH}/heartbeat" 2>/dev/null || exit 0; done ) &
            LOCK_HB_PID=$!
            trap lock_release EXIT
            log "Lock '${name}' acquired (run_id=${LOCK_RUN_ID})"
            return 0
        fi
        [ -d "$LOCK_PATH" ] || continue            # released between our mkdir and now: retry
        owner=$(cat "${LOCK_PATH}/owner" 2>/dev/null)
        age=$(_lock_age "$LOCK_PATH")
        if [ "$age" -le "$LOCK_STALE" ]; then
            log "ERROR: lock '${name}' held by [$(printf '%s' "$owner" | tr '\n' ' ')] (heartbeat ${age}s ago) — another run is in progress; this run did nothing. Re-run after it finishes."
            exit "$LOCK_EXIT_HELD"
        fi
        log "WARN: lock '${name}' is stale (heartbeat ${age}s ago > ${LOCK_STALE}s; owner [$(printf '%s' "$owner" | tr '\n' ' ')]) — breaking it"
        # Rename is atomic: exactly one contender moves the stale lock away.
        stale_dir="${LOCK_PATH}.stale.${LOCK_RUN_ID}"
        mv "$LOCK_PATH" "$stale_dir" 2>/dev/null \
            || { log "ERROR: another run broke lock '${name}' first; this run did nothing"; exit "$LOCK_EXIT_HELD"; }
        if [ "$(cat "${stale_dir}/owner" 2>/dev/null)" != "$owner" ]; then
            # We moved a FRESH lock that another run took after breaking the stale one: put it back.
            mv -T "$stale_dir" "$LOCK_PATH" 2>/dev/null || log "WARN: could not restore lock '${name}' moved by mistake"
            log "ERROR: another run broke lock '${name}' first; this run did nothing"
            exit "$LOCK_EXIT_HELD"
        fi
        rm -rf "$stale_dir"
    done
    log "ERROR: could not take lock '${name}'; this run did nothing"
    exit "$LOCK_EXIT_HELD"
}
```

> **Layout and recovery.** `.nas-sync-state/locks/<job>.lock/` holds `owner` and a
> `heartbeat` file the holder touches every `LOCK_HEARTBEAT` (60s). A lock whose heartbeat is
> older than `LOCK_STALE` (600s) belongs to a dead run — SIGKILL, node loss,
> `activeDeadlineSeconds` — and the next run breaks it automatically. A fixed TTL would not
> work: a walk may legitimately run for up to 24h. Ages are measured on the NAS clock, never
> against pod clocks. The path is under `.nas-sync-state/`, so it is never replicated.

---

## 5. Step 2 — Cluster B: Deploy rsync Server
````

- [ ] **Step 3: Replace the §4.3 script block** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Replace the entire contents of the first ```` ```bash ```` block under the heading `### 4.3 File:` (keep the fences) with:

```bash
#!/bin/bash
#############################################
# Multi-Client Manifest Generator (Cluster B) — v3.16
# ONE find walk; fan-out per-client manifests by a
# stateless lookback window. No markers, no per-client walk.
#
# LIMITS OF mtime DETECTION (see §12.1) — the weekly
# reconcile (§9A.4) is the required repair path for:
#   * renamed/moved files (mv preserves mtime)
#   * new EMPTY directories (only files+symlinks listed)
#   * directory mode/ownership changes
#   * content changed with mtime preserved
#############################################
set +e

SOURCE_PATH="${SOURCE_PATH:-/mnt/nas-source}"
# State lives ON the source NAS (no Kubernetes PVC).
STATE_DIR="${STATE_DIR:-${SOURCE_PATH}/.nas-sync-state}"
CLIENTS_DIR="${STATE_DIR}/clients"
# Registry: lines "<client_id> <lookback_hours>"; # comments + blanks ignored.
REGISTRY_FILE="${REGISTRY_FILE:-/userapp/config/clients.txt}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

[ -r "$REGISTRY_FILE" ] || { log "ERROR: registry $REGISTRY_FILE not readable"; exit 1; }

NOW=$(date +%s)
# v3.16: every temp name carries the run id. $$ alone repeats across containers.
RUN_ID="${HOSTNAME:-unknown}-$$-${NOW}"

# v3.16: one generator at a time (§4.7). Exits 75 if another run holds the lock.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-state-lock.sh" \
    || { log "ERROR: nas-sync-state-lock.sh not found next to this script (§4.7)"; exit 1; }
lock_acquire manifests

mkdir -p "$CLIENTS_DIR"
# Leftovers of crashed runs (any run id, and v3.15's unsuffixed names). Safe: we hold the lock.
rm -f "${CLIENTS_DIR}"/*/sync-manifest.txt.tmp* "${CLIENTS_DIR}"/*/manifest.meta.tmp* 2>/dev/null

log "========================================"
log "Multi-Client Manifest Generator v3.16"
log "  Source: $SOURCE_PATH | State: $STATE_DIR"
log "  Registry: $REGISTRY_FILE"
log "========================================"

# Parse registry -> parallel arrays; pre-create empty temp manifests.
CLIENT_IDS=(); THRESHOLDS=()
while read -r CID HOURS _rest; do
    case "$CID" in ''|\#*) continue;; esac
    case "$HOURS" in ''|*[!0-9]*) log "WARN: bad lookback for '$CID' ('$HOURS') — skipping"; continue;; esac
    THRESH=$(( NOW - HOURS * 3600 ))
    mkdir -p "${CLIENTS_DIR}/${CID}"
    : > "${CLIENTS_DIR}/${CID}/sync-manifest.txt.tmp.${RUN_ID}"
    CLIENT_IDS+=("$CID"); THRESHOLDS+=("$THRESH")
    log "  client=$CID lookback=${HOURS}h threshold=$THRESH"
done < "$REGISTRY_FILE"

[ "${#CLIENT_IDS[@]}" -gt 0 ] || { log "ERROR: no valid clients in registry"; exit 1; }

# awk config: one line per client => id<TAB>threshold<TAB>tmpfile
AWK_CONF="$(mktemp)"
i=0
while [ "$i" -lt "${#CLIENT_IDS[@]}" ]; do
    printf '%s\t%s\t%s\n' "${CLIENT_IDS[$i]}" "${THRESHOLDS[$i]}" \
        "${CLIENTS_DIR}/${CLIENT_IDS[$i]}/sync-manifest.txt.tmp.${RUN_ID}" >> "$AWK_CONF"
    i=$((i+1))
done

log "Walking source (one pass)..."
# v3.15: prune snapshot dirs by NAME at every depth. NetApp exposes .snapshot inside
# EVERY directory (Synology @eaDir, ZFS .zfs likewise) — the v3.14 -path prune only
# matched the one at the top of the export, so the walk descended into every snapshot.
# v3.15: also list symlinks (-type l), which v3.14 silently omitted.
find "$SOURCE_PATH" \
    -name '.snapshot'  -prune -o \
    -name '.snapshots' -prune -o \
    -name '.zfs'       -prune -o \
    -name '@eaDir'     -prune -o \
    -path "$STATE_DIR" -prune -o \
    \( -type f -o -type l \) -printf '%T@ %P\n' 2>/dev/null \
| awk -v conf="$AWK_CONF" '
    BEGIN {
        n = 0
        while ((getline line < conf) > 0) {
            split(line, a, "\t"); n++; thr[n] = a[2] + 0; out[n] = a[3]
        }
        close(conf)
    }
    {
        mt = $1 + 0                         # float epoch mtime
        p = substr($0, index($0, " ") + 1) # path = everything after first space
        for (k = 1; k <= n; k++) if (mt > thr[k]) print p >> out[k]
    }
'

rm -f "$AWK_CONF"

# Publish atomically + write meta. v3.16: meta is written to a temp name and renamed too,
# and a failed publish is an error (v3.15 logged "wrote" even when mv had failed).
FAILED=0
i=0
while [ "$i" -lt "${#CLIENT_IDS[@]}" ]; do
    CID="${CLIENT_IDS[$i]}"
    TMP="${CLIENTS_DIR}/${CID}/sync-manifest.txt.tmp.${RUN_ID}"
    FINAL="${CLIENTS_DIR}/${CID}/sync-manifest.txt"
    META_TMP="${CLIENTS_DIR}/${CID}/manifest.meta.tmp.${RUN_ID}"
    COUNT=$(wc -l < "$TMP" 2>/dev/null | tr -d ' '); [ -n "$COUNT" ] || COUNT=0
    if mv -f "$TMP" "$FINAL"; then
        printf 'generated_at=%s\nwindow_threshold_epoch=%s\nfile_count=%s\n' \
            "$NOW" "${THRESHOLDS[$i]}" "$COUNT" > "$META_TMP" \
            && mv -f "$META_TMP" "${CLIENTS_DIR}/${CID}/manifest.meta"
        log "  wrote $FINAL ($COUNT files)"
    else
        log "ERROR: could not publish $FINAL"
        FAILED=1
    fi
    i=$((i+1))
done

[ "$FAILED" -eq 0 ] || exit 1
log "Done."
```

- [ ] **Step 4: §4.3: note after the block** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

````text
log "Done."
```

### 4.4 File: `cluster-b/scripts/Dockerfile` (CRLF-safe)
````

Replace with:

````text
log "Done."
```

> **One generator at a time (v3.16).** The script takes the `manifests` lock (§4.7) before it
> writes anything. A second run — typically a manual `kubectl create job --from=cronjob/…`
> while the scheduled one is still walking — exits **75** and changes nothing; re-run it after
> the first finishes. Every temp file carries the run id and `manifest.meta` is renamed into
> place, so even a wrongly broken lock cannot tear a published manifest.

### 4.4 File: `cluster-b/scripts/Dockerfile` (CRLF-safe)
````

- [ ] **Step 5: Replace the §4.6 script block** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Replace the entire contents of the first ```` ```bash ```` block under the heading `### 4.6 File:` (keep the fences) with:

```bash
#!/bin/bash
#############################################
# Chunk Generator (Cluster B) — v3.16
# Full-tree file list split round-robin into
# CHUNK_COUNT equal-count lists, consumed by the
# client's chunked parallel reconcile via
# rsync --files-from=chunk-<gen>-NNN.txt.
# Shared by ALL targets: common/chunks/
#############################################
set +e

SOURCE_PATH="${SOURCE_PATH:-/mnt/nas-source}"
STATE_DIR="${STATE_DIR:-${SOURCE_PATH}/.nas-sync-state}"
CHUNKS_DIR="${STATE_DIR}/common/chunks"
CHUNK_COUNT="${CHUNK_COUNT:-24}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

case "$CHUNK_COUNT" in ''|*[!0-9]*) log "ERROR: CHUNK_COUNT must be numeric"; exit 1;; esac
[ "$CHUNK_COUNT" -ge 1 ] || { log "ERROR: CHUNK_COUNT must be >= 1"; exit 1; }

NOW=$(date +%s)
# v3.16: every temp name carries the run id. $$ alone repeats across containers.
RUN_ID="${HOSTNAME:-unknown}-$$-${NOW}"
# v3.16: the generation names every chunk file (chunk-<GEN>-NNN.txt) — see the swap below.
GEN="g${NOW}"
TMP_DIR="${STATE_DIR}/common/.chunks.tmp.${RUN_ID}"
OLD_DIR="${STATE_DIR}/common/.chunks.old.${RUN_ID}"

# v3.16: one generator at a time (§4.7). Exits 75 if another run holds the lock.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-state-lock.sh" \
    || { log "ERROR: nas-sync-state-lock.sh not found next to this script (§4.7)"; exit 1; }
lock_acquire chunks

log "========================================"
log "Chunk Generator v3.16"
log "  Source: $SOURCE_PATH"
log "  Chunks: $CHUNKS_DIR (count=$CHUNK_COUNT, generation=$GEN)"
log "========================================"

# Hygiene: drop orphan dirs from crashed runs (any run id, and v3.15's unsuffixed names).
# Safe because we hold the lock — no other generator is writing.
rm -rf "${STATE_DIR}/common"/.chunks.tmp* "${STATE_DIR}/common"/.chunks.old*
mkdir -p "$TMP_DIR" || { log "ERROR: cannot create $TMP_DIR (source NAS writable?)"; exit 1; }

# Same prune set as the manifest generator (§4.3): snapshot dirs at EVERY depth.
log "Walking source (one pass)..."
find "$SOURCE_PATH" \
    -name '.snapshot'  -prune -o \
    -name '.snapshots' -prune -o \
    -name '.zfs'       -prune -o \
    -name '@eaDir'     -prune -o \
    -path "$STATE_DIR" -prune -o \
    \( -type f -o -type l \) -printf '%P\n' 2>/dev/null \
| split -n "r/${CHUNK_COUNT}" -d -a 3 - "${TMP_DIR}/chunk-${GEN}-"
# split -n r/N = round-robin by line, works on a pipe (no need to know the total first).
# Round-robin also spreads any directory hot-spot evenly across chunks.
# split -n always creates exactly N files (some empty if the tree is tiny).

TOTAL=0
for f in "${TMP_DIR}/chunk-${GEN}-"*; do
    [ -f "$f" ] || continue
    mv -f "$f" "${f}.txt"
    N=$(wc -l < "${f}.txt" 2>/dev/null | tr -d ' '); [ -n "$N" ] || N=0
    TOTAL=$(( TOTAL + N ))
done

if [ "$TOTAL" -eq 0 ]; then
    log "ERROR: walk produced 0 files — refusing to publish empty chunks"
    rm -rf "$TMP_DIR"
    exit 1
fi

printf 'generated_at=%s\ngeneration=%s\nchunk_count=%s\ntotal_files=%s\n' \
    "$NOW" "$GEN" "$CHUNK_COUNT" "$TOTAL" > "${TMP_DIR}/chunks.meta"

# Swap into place. The two mv calls leave a brief window with no chunks dir: a client
# fetch that starts in it fails and falls back (§8.3). A fetch already IN FLIGHT across
# the swap is the subtle case — rsync re-resolves each file by path, so with fixed names
# it would silently get a MIX of old and new chunks (rc=0). Generation-unique names make
# the old names vanish instead: the fetch fails with rc 24, and the client retries or
# falls back. It can never receive a mixed set.
if [ -d "$CHUNKS_DIR" ]; then
    mv -f "$CHUNKS_DIR" "$OLD_DIR" || { log "ERROR: cannot rotate old chunks"; exit 1; }
fi
mkdir -p "$(dirname "$CHUNKS_DIR")"
mv -f "$TMP_DIR" "$CHUNKS_DIR" || { log "ERROR: cannot publish chunks"; exit 1; }
rm -rf "$OLD_DIR"

log "Published $CHUNK_COUNT chunks (generation $GEN), $TOTAL files total → $CHUNKS_DIR"
log "Done."
```

- [ ] **Step 6: §4.6: note before "Disk cost"** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
> **Disk cost.** At 7.4M paths
```

Replace with:

```text
> **Generation-named chunks (v3.16).** Every file is `chunk-<generation>-NNN.txt` and
> `chunks.meta` records `generation=`. A client fetch that overlaps the swap therefore fails
> with rc 24 instead of silently receiving a mix of two generations (which left ~22% of the
> tree unreconciled); the client retries once, then falls back (§8.3). v3.15 clients still
> match the new names with `chunk-*.txt`, so this is safe to roll out source-first.
>
> **Disk cost.** At 7.4M paths
```

- [ ] **Step 7: §4.4: COPY the lock library** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
COPY generate-chunks.sh /userapp/scripts/generate-chunks.sh
```

Replace with:

```text
COPY generate-chunks.sh /userapp/scripts/generate-chunks.sh
COPY nas-sync-state-lock.sh /userapp/scripts/nas-sync-state-lock.sh
```

- [ ] **Step 8: §4.4: dos2unix + chmod list** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
RUN dos2unix /entrypoint.sh \
        /userapp/scripts/generate-manifests.sh \
        /userapp/scripts/generate-chunks.sh \
    && chmod +x /entrypoint.sh \
        /userapp/scripts/generate-manifests.sh \
        /userapp/scripts/generate-chunks.sh
```

Replace with:

```text
RUN dos2unix /entrypoint.sh \
        /userapp/scripts/generate-manifests.sh \
        /userapp/scripts/generate-chunks.sh \
        /userapp/scripts/nas-sync-state-lock.sh \
    && chmod +x /entrypoint.sh \
        /userapp/scripts/generate-manifests.sh \
        /userapp/scripts/generate-chunks.sh \
        /userapp/scripts/nas-sync-state-lock.sh
```

- [ ] **Step 9: §4.4: CRLF guard list** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
RUN for f in /entrypoint.sh \
             /userapp/scripts/generate-manifests.sh \
             /userapp/scripts/generate-chunks.sh; do \
```

Replace with:

```text
RUN for f in /entrypoint.sh \
             /userapp/scripts/generate-manifests.sh \
             /userapp/scripts/generate-chunks.sh \
             /userapp/scripts/nas-sync-state-lock.sh; do \
```

- [ ] **Step 10: §4.5: strip CRLF from the new file too** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
sed -i 's/\r$//' entrypoint.sh generate-manifests.sh generate-chunks.sh 2>/dev/null || true
```

Replace with:

```text
sed -i 's/\r$//' entrypoint.sh generate-manifests.sh generate-chunks.sh nas-sync-state-lock.sh 2>/dev/null || true
```

- [ ] **Step 11: §6.1: Forbid is not a lock** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
  schedule: "50 */2 * * *"
  concurrencyPolicy: Forbid
```

Replace with:

```text
  schedule: "50 */2 * * *"
  # Forbid only stops the controller overlapping its OWN scheduled runs. Manual
  # `create job --from` runs are serialized by the script's lock (§4.7).
  concurrencyPolicy: Forbid
```

- [ ] **Step 12: §6.3: Forbid is not a lock** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
  schedule: "0 0 * * 0"
  concurrencyPolicy: Forbid
```

Replace with:

```text
  schedule: "0 0 * * 0"
  # Forbid only stops the controller overlapping its OWN scheduled runs. Manual
  # `create job --from` runs are serialized by the script's lock (§4.7).
  concurrencyPolicy: Forbid
```

- [ ] **Step 13: §6.3: note on overlapping the manifest job** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

````text
```bash
# Only if using chunked parallel reconcile:
kubectl apply -f cluster-b/cronjob-chunks.yaml
```
````

Replace with:

````text
```bash
# Only if using chunked parallel reconcile:
kubectl apply -f cluster-b/cronjob-chunks.yaml
```

> **Overlap with the manifest job (v3.16 note).** On Sundays this walk runs alongside the
> `:50` manifest runs (§6.1). That is safe — the two jobs write disjoint paths and each takes
> only its own lock (§4.7) — but it doubles metadata load on the source NAS while both walk.
> If that load matters, move this schedule to a quiet window that still ends before the
> reconcile (§9A.4).
````

- [ ] **Step 14: §14: list nas-sync-state-lock.sh** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
    └── generate-chunks.sh         # 4.6  (v3.15, optional: equal-count chunk lists)
```

Replace with:

```text
    ├── generate-chunks.sh         # 4.6  (v3.15, optional: equal-count chunk lists)
    └── nas-sync-state-lock.sh     # 4.7  (v3.16, generator lock — sourced by 4.3 + 4.6)
```

- [ ] **Step 15: Run the checker and the cases**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md
bash scripts/test-guide-behavior.sh --native --case lock --case swap cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
All checks passed (0 warning(s))
All 8 checks passed
```

Optional, to see the retry path: rerun with `NGB_KEEP=1 … --case swap` and read `swap.log` in the printed workspace. You should see `Chunk files vanished mid-fetch (rc=24) … retrying once`, followed by `Using 24 server-generated chunks (generation=g…`.

- [ ] **Step 16: Commit**

```bash
git add cross-cluster-rsync-guide-v3.16-consolidated.md
git commit -m "v3.16: generator lock (§4.7), per-run temp names, generation-named chunk files"
```

---
### Task 6: Graceful SIGTERM on the CronJob path (§8.2, §8.4, §8.5, §8.6, §9A.x)

Fixes F6 (CronJob path) and F7. The rule is that one place sends SIGTERM and every other shell waits.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.16-consolidated.md`, in §8.2, §8.4, §8.5, §8.6, §9A.2, §9A.4 and §9A.5.

**Interfaces:**
- Consumes: `wait_child`, `term_trap_install` and `check_term` (Task 3).
- Produces:
  - The status line in `.nas-sync-status/last-run` gains the suffix ` interrupted=TERM`.
  - An interrupted run exits `143` and never writes `last-success`.

- [ ] **Step 1: Run the failing case**

```bash
bash scripts/test-guide-behavior.sh --native --case signal cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
12 check(s) FAILED, 0 passed
```

- [ ] **Step 2: §8.2: source the library** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
die() { log_error "$1"; exit "${2:-1}"; }

# v3.15: rsync 23/24 are NORMAL on a live source
```

Replace with:

```text
die() { log_error "$1"; exit "${2:-1}"; }

# v3.16: shared helpers (§8.11). On SIGTERM, let rsync save its partial, then stop.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh" || die "nas-sync-lib.sh not found (§8.11)"
term_trap_install

# v3.15: rsync 23/24 are NORMAL on a live source
```

- [ ] **Step 3: §8.2 + §8.4: re-check after each preflight wait** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly 2 times — replace **all 2**):

```text
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES}) — sidecar may still be starting"
        sleep "$PREFLIGHT_WAIT"
        i=$((i+1))
```

Replace with:

```text
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES}) — sidecar may still be starting"
        sleep "$PREFLIGHT_WAIT"
        check_term
        i=$((i+1))
```

- [ ] **Step 4: §8.2: stop after rsync on SIGTERM** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
RC=${PIPESTATUS[0]}

rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: rsync_rc=$RC exit=$SYNC_EXIT, ${DUR}s ==="
```

Replace with:

```text
RC=${PIPESTATUS[0]}
check_term

rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: rsync_rc=$RC exit=$SYNC_EXIT, ${DUR}s ==="
```

- [ ] **Step 5: §8.4: header version** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
# NAS Sync — INCREMENTAL mode (v3.15)
```

Replace with:

```text
# NAS Sync — INCREMENTAL mode (v3.16)
```

- [ ] **Step 6: §8.4: source the library** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
die() { log_error "$1"; exit "${2:-1}"; }

# rsync 23/24 are normal on a live source — see §8.2.
rsync_rc_ok() {
    case "$1" in
        0)  return 0 ;;
        24) log "NOTE
```

Replace with:

```text
die() { log_error "$1"; exit "${2:-1}"; }

# v3.16: shared helpers (§8.11). On SIGTERM, let rsync save its partial, then stop.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh" || die "nas-sync-lib.sh not found (§8.11)"
term_trap_install

# rsync 23/24 are normal on a live source — see §8.2.
rsync_rc_ok() {
    case "$1" in
        0)  return 0 ;;
        24) log "NOTE
```

- [ ] **Step 7: §8.4: after the manifest fetch** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
    "${REMOTE_URL}/${MANIFEST_NAME}" "$MANIFEST_LOCAL" 2>&1
FETCH_RC=$?
```

Replace with:

```text
    "${REMOTE_URL}/${MANIFEST_NAME}" "$MANIFEST_LOCAL" 2>&1
FETCH_RC=$?
check_term
```

- [ ] **Step 8: §8.4: after the full-sync fallback** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
    run_full_sync
    RC=$?
    rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC
    DUR=
```

Replace with:

```text
    run_full_sync
    RC=$?
    check_term
    rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC
    DUR=
```

- [ ] **Step 9: §8.4: after the meta fetch** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
        "${REMOTE_URL}/${META_NAME}" "$META_LOCAL" >/dev/null 2>&1
```

Replace with:

```text
        "${REMOTE_URL}/${META_NAME}" "$META_LOCAL" >/dev/null 2>&1
    check_term
```

- [ ] **Step 10: §8.4: after the sync** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
        RC=${PIPESTATUS[0]}
    fi
fi

rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC
```

Replace with:

```text
        RC=${PIPESTATUS[0]}
    fi
fi
check_term

rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC
```

- [ ] **Step 11: §8.5: source the library** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [dispatch] $1"; }
```

Replace with:

```text
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [dispatch] $1"; }

# v3.16: shared helpers (§8.11) — wait_child.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh" || { log "ERROR: nas-sync-lib.sh not found (§8.11)"; exit 1; }
```

- [ ] **Step 12: §8.5: run the mode script in the background and wait** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
START=$(date +%s)
"$SCRIPT"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
log "Mode $SYNC_MODE finished: exit=$RC elapsed=${ELAPSED}s"
```

Replace with:

```text
START=$(date +%s)
# v3.16: never exit before the mode script does. On SIGTERM, pass it on and keep waiting —
# the mode script is letting rsync move its partial file into .rsync-partial/. If this shell
# exited first, the chain up to tini (PID 1) would unwind and the kernel would SIGKILL rsync
# mid-cleanup, leaving a .<name>.XXXXXX temp file in the target tree. Not `exec`: the status
# write below must run after the mode script.
GOT_TERM=""
CHILD=""
trap 'GOT_TERM=1; [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null' TERM INT
"$SCRIPT" &
CHILD=$!
wait_child "$CHILD"
RC=$WAIT_RC
# An interrupted run is never a success, whatever the mode script returned.
[ -n "$GOT_TERM" ] && [ "$RC" -eq 0 ] && RC=143
ELAPSED=$(( $(date +%s) - START ))
log "Mode $SYNC_MODE finished: exit=$RC elapsed=${ELAPSED}s${GOT_TERM:+ (interrupted by SIGTERM)}"
```

- [ ] **Step 13: §8.5: status line marks interruptions** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
        LINE="ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ') mode=${SYNC_MODE} client=${CLIENT_ID:-none} exit=${RC} elapsed=${ELAPSED}s host=$(hostname)"
```

Replace with:

```text
        # v3.16: " interrupted=TERM" is appended when the run was stopped by SIGTERM.
        LINE="ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ') mode=${SYNC_MODE} client=${CLIENT_ID:-none} exit=${RC} elapsed=${ELAPSED}s host=$(hostname)${GOT_TERM:+ interrupted=TERM}"
```

- [ ] **Step 14: §8.5: reading note** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
> older than **2× the CronJob interval**, investigate (§13). `last-run` newer than
> `last-success` means the most recent attempt failed.
```

Replace with:

```text
> older than **2× the CronJob interval**, investigate (§13). `last-run` newer than
> `last-success` means the most recent attempt failed.
>
> **`interrupted=TERM` (v3.16)** at the end of `last-run` means the pod was stopped
> (deadline, node drain, rollout, `kubectl delete`) while syncing. rsync kept its partial file
> in `.rsync-partial/`, so the next run resumes it; the run is recorded as `exit=143` and
> never counts as a success.
```

- [ ] **Step 15: §8.6: top of the chain signals its group and waits** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [wrapper] $1"; }

log "=== Wrapper start (SYNC_MODE=${SYNC_MODE:-standard}) ==="
/userapp/scripts/dispatch-sync.sh
SYNC_EXIT=$?
log "Sync exited: $SYNC_EXIT"
```

Replace with:

```text
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [wrapper] $1"; }

# v3.16: shared helpers (§8.11) — wait_child.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh" || { log "ERROR: nas-sync-lib.sh not found (§8.11)"; exit 1; }

log "=== Wrapper start (SYNC_MODE=${SYNC_MODE:-standard}) ==="

# v3.16: this shell is the top of the CronJob chain: tini → wrapper → dispatcher → mode
# script → rsync. On SIGTERM it signals its own process group ONCE — so delivery does not
# depend on `tini -g` — and then WAITS. v3.15 had no trap: this shell died at once, tini
# (PID 1) exited, and the kernel SIGKILLed rsync before it could save its partial file.
GOT_TERM=""
on_term() {
    [ -n "$GOT_TERM" ] && return     # kill -TERM 0 below signals this shell too
    GOT_TERM=1
    log "SIGTERM — signalling the sync, waiting for rsync to stop cleanly"
    kill -TERM 0 2>/dev/null
}
trap on_term TERM INT
/userapp/scripts/dispatch-sync.sh &
wait_child $!
SYNC_EXIT=$WAIT_RC
log "Sync exited: $SYNC_EXIT"

if [ -n "$GOT_TERM" ]; then
    # The pod is being deleted: kubelet is stopping istio-proxy itself, nothing to quit.
    log "=== Interrupted: exit $SYNC_EXIT ==="
    exit "$SYNC_EXIT"
fi
```

- [ ] **Step 16: §9A.2, §9A.4, §9A.5: grace period on every client CronJob pod** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly 3 times — replace **all 3**):

```text
            proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
        spec:
          containers:
```

Replace with:

```text
            proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
        spec:
          # v3.16: time for rsync to stop cleanly when the pod is deleted (§8.11).
          terminationGracePeriodSeconds: 60
          containers:
```

- [ ] **Step 17: Run the checker and the case**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md
bash scripts/test-guide-behavior.sh --native --case signal cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
All checks passed (0 warning(s))
All 12 checks passed
```


- [ ] **Step 18: Commit**

```bash
git add cross-cluster-rsync-guide-v3.16-consolidated.md
git commit -m "v3.16: graceful SIGTERM on the CronJob path; status records interrupted=TERM; grace periods"
```

---
### Task 7: Graceful SIGTERM on the Deployment path (§8.7, §8.8, §10B.1)

Fixes F6 for runs launched by cron, which sit in their own session where `tini -g` can't reach them.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.16-consolidated.md`, in §8.7, §8.8 and §10B.1.

**Interfaces:**
- Consumes: `wait_child` (Task 3).
- Produces: env `SHUTDOWN_WAIT` (default 50). It must stay below `terminationGracePeriodSeconds` (60).

- [ ] **Step 1: Run the failing case (takes ~2 minutes)**

```bash
bash scripts/test-guide-behavior.sh --native --slow --case deploy cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
6 check(s) FAILED, 0 passed
```

- [ ] **Step 2: §8.7: source the library, SHUTDOWN_WAIT, banner** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

CRON_SCHEDULE="${CRON_SCHEDULE:-0 */2 * * *}"

log "=== NAS Sync Client v3.15 (Deployment, SYNC_MODE=${SYNC_MODE:-standard}) ==="
```

Replace with:

```text
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# v3.16: shared helpers (§8.11) — wait_child.
. "$(dirname "${BASH_SOURCE[0]}")/nas-sync-lib.sh" || { log "ERROR: nas-sync-lib.sh not found (§8.11)"; exit 1; }

CRON_SCHEDULE="${CRON_SCHEDULE:-0 */2 * * *}"
# Keep below terminationGracePeriodSeconds (§10B.1): time allowed for in-flight runs to stop.
SHUTDOWN_WAIT="${SHUTDOWN_WAIT:-50}"

log "=== NAS Sync Client v3.16 (Deployment, SYNC_MODE=${SYNC_MODE:-standard}) ==="
```

- [ ] **Step 3: §8.7: supervise instead of exec cron** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
log "=== INITIAL SYNC (no time limit) ==="
flock -n /var/lock/nas-sync.lock /userapp/scripts/dispatch-sync.sh
log "Initial sync done (exit $?). Starting cron..."

exec cron -f
```

Replace with:

```text
# v3.16: this shell stays tini's child for the pod's whole life — no `exec cron -f`. On
# SIGTERM it stops cron, signals every in-flight run, and waits for them to finish. cron
# gives each job its OWN session, so `tini -g` never reached cron-launched runs: in v3.15
# they were SIGKILLed mid-transfer whenever the pod was deleted or rolled.
GOT_TERM=""
CRON_PID=""
# Process groups of all running syncs: the initial sync (ours) and each cron job's.
run_pgids() { ps -eo pgid=,args= | awk '/\/userapp\/scripts\/dispatch-sync\.sh/ {print $1}' | sort -u; }
on_term() {
    [ -n "$GOT_TERM" ] && return     # signalling our own group re-enters this trap
    GOT_TERM=1
    log "SIGTERM — stopping cron, signalling in-flight sync runs"
    [ -n "$CRON_PID" ] && kill -TERM "$CRON_PID" 2>/dev/null
    local pg
    for pg in $(run_pgids); do kill -TERM -- "-$pg" 2>/dev/null; done
}
trap on_term TERM INT
drain_and_exit() {
    local i=0
    while [ "$i" -lt "$SHUTDOWN_WAIT" ] && [ -n "$(run_pgids)" ]; do sleep 1; i=$((i+1)); done
    [ -n "$(run_pgids)" ] && log "WARN: a sync is still running after ${SHUTDOWN_WAIT}s — it will be SIGKILLed"
    log "=== Shutdown complete ==="
    exit 143
}

log "=== INITIAL SYNC (no time limit) ==="
flock -n /var/lock/nas-sync.lock /userapp/scripts/dispatch-sync.sh &
wait_child $!
[ -n "$GOT_TERM" ] && drain_and_exit
log "Initial sync done (exit $WAIT_RC). Starting cron..."

cron -f &
CRON_PID=$!
wait_child "$CRON_PID"
[ -n "$GOT_TERM" ] && drain_and_exit
log "ERROR: cron exited unexpectedly (rc=$WAIT_RC) — exiting so the pod restarts"
exit 1
```

- [ ] **Step 4: §8.7: shutdown note** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
> is still used on the initial sync, which starts immediately at pod boot.
```

Replace with:

```text
> is still used on the initial sync, which starts immediately at pod boot.
>
> **Shutdown (v3.16).** The entrypoint no longer `exec`s cron: it stays alive to stop cron and
> signal every in-flight run when the pod is deleted, then waits up to `SHUTDOWN_WAIT` (50s)
> for them — keep that below `terminationGracePeriodSeconds` (§10B.1). See §8.11.
```

- [ ] **Step 5: §8.8: -g is now belt and braces** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
# Default ENTRYPOINT = CronJob wrapper.
# Deployment overrides command to use entrypoint-deployment.sh.
```

Replace with:

```text
# Default ENTRYPOINT = CronJob wrapper.
# Deployment overrides command to use entrypoint-deployment.sh.
# -g (signal the whole process group) is belt and braces since v3.16: the wrapper and the
# Deployment entrypoint signal the sync themselves and wait for it (§8.11).
```

- [ ] **Step 6: §10B.1: grace period** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      containers:
```

Replace with:

```text
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      # v3.16: covers SHUTDOWN_WAIT (50s, §8.7) plus margin, so in-flight rsyncs stop cleanly.
      terminationGracePeriodSeconds: 60
      containers:
```

- [ ] **Step 7: §10B.1: command comment** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
          # Override ENTRYPOINT: use deployment entry (initial sync + cron loop)
```

Replace with:

```text
          # Override ENTRYPOINT: use deployment entry (initial sync + cron loop).
          # Keep tini as PID 1; the entrypoint itself handles SIGTERM (§8.7).
```

- [ ] **Step 8: Run the checker and the case**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md
bash scripts/test-guide-behavior.sh --native --slow --case deploy cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
All checks passed (0 warning(s))
All 6 checks passed
```


- [ ] **Step 9: Commit**

```bash
git add cross-cluster-rsync-guide-v3.16-consolidated.md
git commit -m "v3.16: Deployment entrypoint supervises cron and stops in-flight runs cleanly"
```

---
### Task 8: Static v3.16 regression checks (`check-guide.sh` section 10)

**Files:**
- Modify: `scripts/check-guide.sh`

**Interfaces:**
- Consumes: the `check_has` helper that already exists in section 9 (a fixed-string `grep`).
- Produces: section "10. v3.16 defect-fix regressions". It runs for `*v3.1[6-9]*` and `*v3.[2-9]*` guides, and warns and skips for older ones.

- [ ] **Step 1: Header: mention the behavior suite** — `scripts/check-guide.sh`

Find (occurs exactly once):

```text
# so "tests" mean proving the blocks are valid and the document is internally
# consistent. Run this before every commit that touches a guide.
```

Replace with:

```text
# so "tests" mean proving the blocks are valid and the document is internally
# consistent. Run this before every commit that touches a guide.
# Runtime behavior (rsync, signals, locks) is covered by scripts/test-guide-behavior.sh.
```

- [ ] **Step 2: Add the v3.16 regression block** — `scripts/check-guide.sh`

Find (occurs exactly once):

```text
      *) warn "pre-v3.15 guide — skipping v3.15 regression checks" ;;
    esac
done
```

Replace with:

```text
      *) warn "pre-v3.15 guide — skipping v3.15 regression checks" ;;
    esac

    # ---------------------------------------------------------------
    head2 "10. v3.16 defect-fix regressions"
    # IDs are the findings in docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md §2.
    check_absent() { if grep -qF -e "$2" -- "$GUIDE"; then fail "$1 — must not appear: $2"; else pass "$1"; fi; }
    case "$GUIDE" in
      *v3.1[6-9]*|*v3.[2-9]*)
        check_has    "F1: chunk files carry their generation"           "generation="
        check_has    "F1: client retries an inconsistent chunk set"     "CHUNK_RETRY_WAIT"
        check_has    "F2: manifest generator takes the state-dir lock"  "lock_acquire manifests"
        check_has    "F2: chunk generator takes the state-dir lock"     "lock_acquire chunks"
        check_has    "F2: lock library is COPYed into the server image" "COPY nas-sync-state-lock.sh"
        check_has    "F3/F4: folder names travel via --files-from"      "--from0 --files-from=-"
        check_has    "F3/F4: one shared top-level lister"               "list_top_dirs"
        check_has    "F3/F4: library is COPYed into the client image"   "COPY nas-sync-lib.sh"
        check_has    "F4: the lister's perl is checked at build time"   "command -v perl"
        check_absent "F4: v3.15 \$NF folder parser is gone"             '$NF != "."'
        check_has    "F5: top-level pass is non-recursive"              "--no-recursive --dirs"
        # Every rsync command line with --dirs must be non-recursive: -a implies -r.
        if grep -E 'rsync .*--dirs' "$GUIDE" | grep -vqF -e '--no-recursive --dirs'; then
            fail "F5: a recursive '-a --dirs' rsync is back (copies the whole tree serially)"
        else
            pass "F5: no recursive '--dirs' rsync"
        fi
        check_has    "F6: wrapper signals its process group"            "kill -TERM 0 2>/dev/null"
        check_has    "F6: dispatcher waits for the mode script"         'wait_child "$CHILD"'
        check_has    "F6: entrypoint waits for cron and its runs"       'wait_child "$CRON_PID"'
        # A command line, not prose: comments may explain why it is gone.
        if grep -qE '^[[:space:]]*exec cron' "$GUIDE"; then
            fail "F6: the Deployment entrypoint execs cron again (cron-launched runs lose SIGTERM)"
        else
            pass "F6: entrypoint does not exec cron"
        fi
        GRACE=$(grep -c 'terminationGracePeriodSeconds: 60' "$GUIDE")
        if [ "$GRACE" -ge 4 ]; then pass "F6: grace period on all $GRACE client pod specs"; else fail "F6: terminationGracePeriodSeconds: 60 on $GRACE pod spec(s), expected 4 (§9A.2, §9A.4, §9A.5, §10B.1)"; fi
        check_has    "F7: status records interruptions"                 "interrupted=TERM"
        ;;
      *) warn "pre-v3.16 guide — skipping v3.16 regression checks" ;;
    esac
done
```

- [ ] **Step 3: It passes on v3.16 and still passes (with one warning) on v3.15**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md | sed -n '/10. v3.16/,$p' | tail -3
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.15-consolidated.md | tail -1
```

Expected:

```text
  ok   F7: status records interruptions

All checks passed (0 warning(s))
All checks passed (1 warning(s))
```


- [ ] **Step 4: It catches regressions — each probe must print a FAIL**

```bash
G=cross-cluster-rsync-guide-v3.16-consolidated.md
try() { sed -e "$1" $G > /tmp/regress-v3.16.md; printf '%-28s → ' "$2"; bash scripts/check-guide.sh /tmp/regress-v3.16.md | grep -m1 FAIL; }
try 's/--no-recursive --dirs "\${REMOTE_URL}/--dirs "${REMOTE_URL}/' 'recursive top-level pass'
try 's/^cron -f &$/exec cron -f/'                                'exec cron'
try 's/kill -TERM 0 2>\/dev\/null/true/'                         'no group signal'
try 's/^wait_child "\$CHILD"$/wait/'                             'dispatcher stops waiting'
try '0,/terminationGracePeriodSeconds: 60/s//terminationGracePeriodSeconds: 30/' 'one grace period dropped'
rm -f /tmp/regress-v3.16.md
```

Expected:

```text
recursive top-level pass     →   FAIL F5: top-level pass is non-recursive — expected to find: --no-recursive --dirs
exec cron                    →   FAIL F6: the Deployment entrypoint execs cron again (cron-launched runs lose SIGTERM)
no group signal              →   FAIL F6: wrapper signals its process group — expected to find: kill -TERM 0 2>/dev/null
dispatcher stops waiting     →   FAIL F6: dispatcher waits for the mode script — expected to find: wait_child "$CHILD"
one grace period dropped     →   FAIL F6: terminationGracePeriodSeconds: 60 on 3 pod spec(s), expected 4 (§9A.2, §9A.4, §9A.5, §10B.1)
```

Static checks are a tripwire, not proof. For example, a dispatcher that runs the mode script in the foreground again would pass them, and only the behavior suite's `signal` case catches it. That is why Task 11 runs both suites.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-guide.sh
git commit -m "check-guide: v3.16 regression assertions (section 10)"
```

---
### Task 9: Guide documentation (header, §11, §13, §14, consolidation table, appendix)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.16-consolidated.md`

**Interfaces:**
- Produces:
  - Troubleshooting headings that runbook Task 10 links to by name: `Generator Job Failed: lock '…' held by […] (exit 75)` and `Status shows interrupted=TERM`.
  - The appendix heading `Also required when coming from v3.15 → v3.16`.

- [ ] **Step 1: Header: what v3.16 fixes** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
>   for everything mtime-based detection cannot see (§12.1), not an optional extra.
>
> **One image, selectable behavior**
```

Replace with:

```text
>   for everything mtime-based detection cannot see (§12.1), not an optional extra.
>
> **v3.16 fixes the 2026-10 review findings** — each reproduced against v3.15's own scripts
> first; evidence in `docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md`:
> - **Chunk generations** (§4.6, §8.3) — a reconcile can no longer receive a silent mix of two
>   chunk generations, which left ~22% of the tree unreconciled.
> - **One generator at a time** (§4.7) — a manual `kubectl create job --from=…` can no longer
>   tear the manifest or publish a half-written chunk set.
> - **Folder names with any character** (§8.11, §8.3, §8.10) — spaces, CJK, quotes and glob
>   characters no longer break the reconcile fallback or blind the verify job.
> - **Graceful shutdown** (§8.5–§8.7, §8.11) — SIGTERM lets rsync save its partial file and is
>   recorded in the status file; v3.15 was SIGKILLed mid-file on every pod deletion.
>
> **One image, selectable behavior**
```

- [ ] **Step 2: §11: v3.16 checks** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
### Deployment
```

Replace with:

````text
### v3.16 checks

```bash
# 1. Generator lock: a manual run while another run of the same generator is walking exits 75
#    and changes nothing.
kubectl --context cluster-b create job --from=cronjob/nas-sync-manifest lock-test -n ea-pmc
kubectl --context cluster-b logs -n ea-pmc -l job-name=lock-test | grep -E "Lock 'manifests' acquired|held by"
#    Expected: "acquired" if nothing else was running, otherwise "held by [...]" and a Failed job.
kubectl --context cluster-b delete job lock-test -n ea-pmc

# 2. Chunk generation recorded.
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  cat /mnt/nas-source/.nas-sync-state/common/chunks/chunks.meta
#    Expected: generated_at=… generation=g… chunk_count=24 total_files=…

# 3. Graceful shutdown: delete a running sync pod, then read the status file.
kubectl create job --from=cronjob/nas-sync-reconcile term-test -n ea-pmc
sleep 120
kubectl delete pod -n ea-pmc -l job-name=term-test --wait=true
kubectl delete job term-test -n ea-pmc          # stop the replacement pod the Job would start
kubectl exec <any-pod> -n ea-pmc -c nas-sync-client -- \
  cat /mnt/nas-target/.nas-sync-status/last-run
#    Expected: … exit=143 … interrupted=TERM

# 4. Behavior suite (runs on a workstation, not the cluster): every v3.16 fix exercised
#    against a real rsync daemon, tini as PID 1, and cron.
bash scripts/test-guide-behavior.sh --slow
```

### Deployment
````

- [ ] **Step 3: §13: chunk fallback table rows** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
| `chunks.meta present but no chunk-*.txt` | Chunk job was interrupted mid-publish | Re-run it; the atomic swap means the next run self-heals |
```

Replace with:

```text
| `chunks.meta present but no chunk files` | Chunk job was interrupted mid-publish | Re-run it; the next run self-heals |
| `Chunk files vanished mid-fetch (rc=24)` | The fetch overlapped the chunk job's swap (v3.16) | Nothing — the client retries once (`CHUNK_RETRY_WAIT`) and uses the new generation |
| `Chunk set inconsistent (generation …)` | Same, caught by the generation check | Nothing if the retry succeeds; if it repeats weekly, the chunk job runs into the reconcile — schedule it earlier |
| `WARN: chunks.meta has no generation` | Server still on v3.15 (e.g. after a rollback) | Upgrade the server image (§4.5) |
```

- [ ] **Step 4: §13: two new entries (before §14)** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text

---

## 14. File Checklist
```

Replace with:

````text

### Generator Job Failed: `lock '…' held by […]` (exit 75)

Another run of the same generator was already walking (v3.16, §4.7) — usually a manual
`kubectl create job --from=cronjob/…` overlapped the scheduled run, or the reverse. The run
that hit the lock **changed nothing**.

```bash
kubectl --context cluster-b get jobs -n ea-pmc -l 'role in (manifest,chunks)' --sort-by=.metadata.creationTimestamp | tail -5
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  sh -c 'ls -la /mnt/nas-source/.nas-sync-state/locks/; cat /mnt/nas-source/.nas-sync-state/locks/*/owner'
```

- Wait for the holder to finish, then re-run if you still need the run. In runbook S4, a run
  that started before you edited the registry does not include the new client.
- A lock whose `heartbeat` is older than `LOCK_STALE` (600s) belongs to a dead run and the next
  run breaks it (`WARN: lock … is stale`). Never delete a lock by hand while its heartbeat is
  fresh — a run is still writing.

### Status shows `interrupted=TERM`

The pod was stopped mid-sync: `activeDeadlineSeconds`, a node drain, a Deployment rollout (for
example after editing `SYNC_MODE`), or `kubectl delete`. Since v3.16 rsync stops cleanly: the
partial file is in `.rsync-partial/` and the next run resumes it. If it recurs on the same
CronJob, the run no longer fits its `activeDeadlineSeconds` — raise it (§9A.4) or speed the
sync up (runbook S13). A `WARN: a sync is still running after 50s` line in a Deployment's log
means `SHUTDOWN_WAIT` was not enough; raise it together with `terminationGracePeriodSeconds`.

---

## 14. File Checklist
````

- [ ] **Step 5: §14 Deploy Order: server step** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
1. Build & push server image v3.15            (Step 1: write §4.2/§4.3/§4.6, then §4.5)
```

Replace with:

```text
1. Build & push server image v3.16            (Step 1: write §4.2/§4.3/§4.6/§4.7, then §4.5)
```

- [ ] **Step 6: §14 Deploy Order: client step** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
5. Build & push client image v3.15            (Step 5: write §8.2–§8.7 + §8.10, then §8.9)
```

Replace with:

```text
5. Build & push client image v3.16            (Step 5: write §8.2–§8.7 + §8.10 + §8.11, then §8.9)
```

- [ ] **Step 7: What This Consolidates: column header** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
| Capability | Source Version | Status in v3.15 |
```

Replace with:

```text
| Capability | Source Version | Status in v3.16 |
```

- [ ] **Step 8: What This Consolidates: v3.16 rows** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
| Per-worker failure tally in parallel mode | v3.15 | ✓ (§8.3) |

Full rationale, evidence and failure scenarios for every v3.15 row:
`docs/reviews/2026-07-22-nas-sync-architecture-review.md`.
```

Replace with:

```text
| Per-worker failure tally in parallel mode | v3.15 | ✓ (§8.3) |
| **Defect fixes (v3.16)** | | |
| Chunk generations — no silent mixed chunk set | v3.16 | ✓ (§4.6, §8.3) — a mixed set left ~22% unreconciled |
| One generator at a time (NFS `mkdir` lock + heartbeat) | v3.16 | ✓ (§4.7, §4.3, §4.6) — overlapping runs tore manifests |
| Per-run temp names, atomic `manifest.meta` | v3.16 | ✓ (§4.3, §4.6) |
| Folder names with any character (`--files-from --from0`) | v3.16 | ✓ (§8.11, §8.3) — spaces, CJK, quotes, glob characters |
| Verify tier 2 sees every folder and reports rsync errors | v3.16 | ✓ (§8.10) — was blind to the same names |
| Sync machinery never replicated by the fallback | v3.16 | ✓ (§8.11) — `.nas-sync-state/` was copied to targets |
| Top-level pass non-recursive | v3.16 | ✓ (§8.3) — `-a --dirs` was a full serial sync |
| Fallback proves every unit ran | v3.16 | ✓ (§8.3) — an aborted xargs reported "all OK" |
| Graceful SIGTERM on every path | v3.16 | ✓ (§8.5–§8.7, §8.11, §9A.2, §9A.4, §9A.5, §10B.1) — rsync was SIGKILLed mid-file |
| Interrupted runs recorded (`interrupted=TERM`) | v3.16 | ✓ (§8.5) |

Full rationale, evidence and failure scenarios for every v3.15 row:
`docs/reviews/2026-07-22-nas-sync-architecture-review.md`. For every v3.16 row:
`docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md`.
```

- [ ] **Step 9: Appendix: v3.15 → v3.16** — `cross-cluster-rsync-guide-v3.16-consolidated.md`

Find (occurs exactly once):

```text
> Nothing on the source NAS needs migrating: `.nas-sync-state/clients/<id>/` is unchanged and
> `common/chunks/` is created on first use.
```

Replace with:

```text
> Nothing on the source NAS needs migrating: `.nas-sync-state/clients/<id>/` is unchanged and
> `common/chunks/` is created on first use.

### Also required when coming from v3.15 → v3.16

No state migration. Everything below is a rebuild plus small manifest edits; rollback is a tag
change in either direction.

1. **Let in-flight generator runs finish.** A v3.15 generator takes no lock, so it could
   overlap the first v3.16 run: `kubectl --context cluster-b get jobs -n ea-pmc -l 'role in (manifest,chunks)'`
   must show nothing active.
2. **Source side first.** Add §4.7 (`nas-sync-state-lock.sh`), update §4.3, §4.6 and the §4.4
   Dockerfile, rebuild the server image as `:3.16` (§4.5), roll the server Deployment, and
   re-apply §6.1 and §6.3. v3.15 clients keep working: they match the new chunk names, and a
   fetch that overlaps a swap now fails and falls back instead of mixing.
3. **Then each target.** Add §8.11 (`nas-sync-lib.sh`), update §8.2–§8.8 and §8.10, rebuild
   the client image as `:3.16` (§8.9), and re-apply §9A.2, §9A.4 and §9A.5 (new image tag and
   `terminationGracePeriodSeconds`), plus §10B.1 if you run the Deployment.
4. **Confirm** with §11's v3.16 checks.

> New on the source NAS: `.nas-sync-state/locks/` (ignored by v3.15, never replicated). Old
> `.chunks.tmp`, `.chunks.old` and `sync-manifest.txt.tmp` leftovers are cleaned up by the
> first v3.16 run.
```

- [ ] **Step 10: Run the checker**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md
```

Expected:

```text
All checks passed (0 warning(s))
```


- [ ] **Step 11: Commit**

```bash
git add cross-cluster-rsync-guide-v3.16-consolidated.md
git commit -m "v3.16 guide docs: header, §11 checks, §13 entries, §14, consolidation table, v3.15→v3.16 appendix"
```

---
### Task 10: Runbook and CLAUDE.md

**Files:**
- Modify: `docs/nas-sync-operations-runbook.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the guide headings from Task 9, which the new runbook rows reference by name.

- [ ] **Step 1: Companion line** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

```text
**Companion to** `cross-cluster-rsync-guide-v3.15-consolidated.md`
```

Replace with:

```text
**Companion to** `cross-cluster-rsync-guide-v3.16-consolidated.md`
```

- [ ] **Step 2: Image tags** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly 9 times — replace **all 9**):

```text
:3.15
```

Replace with:

```text
:3.16
```

- [ ] **Step 3: S1: lock held on the bootstrap run** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

````text
kubectl --context cluster-b logs job/bootstrap -n ea-pmc
```
````

Replace with:

````text
kubectl --context cluster-b logs job/bootstrap -n ea-pmc
# Failed with "lock 'manifests' held by [...]" (exit 75)? A scheduled run was already
# walking: wait for it (guide §13), then re-run this job.
```
````

- [ ] **Step 4: S2: lock held on seed-chunks** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

````text
kubectl --context cluster-b wait --for=condition=complete job/seed-chunks -n ea-pmc --timeout=14400s
```
````

Replace with:

````text
kubectl --context cluster-b wait --for=condition=complete job/seed-chunks -n ea-pmc --timeout=14400s
# Failed with "lock 'chunks' held" (exit 75)? The scheduled chunk job is running — wait for it
# instead; its output serves the bulk seed just as well.
```
````

- [ ] **Step 5: S4: lock held on reg-nas-c** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

```text
kubectl --context cluster-b wait --for=condition=complete job/reg-nas-c -n ea-pmc --timeout=7200s
```

Replace with:

```text
kubectl --context cluster-b wait --for=condition=complete job/reg-nas-c -n ea-pmc --timeout=7200s
#    Failed with "lock 'manifests' held" (exit 75)? A scheduled run is walking. It read
#    clients.txt BEFORE your edit, so it will not include nas-c: wait for it, then re-run.
```

- [ ] **Step 6: S5: interrupted=TERM** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

```text
`last-success` older than 2× the CronJob interval → investigate ([S12](#s12--triage-decision-tree)).
```

Replace with:

```text
`last-success` older than 2× the CronJob interval → investigate ([S12](#s12--triage-decision-tree)).
`interrupted=TERM` at the end of `last-run` means the pod was stopped mid-sync (deadline,
drain, rollout); the partial file is kept and the next run resumes it (guide §13).
```

- [ ] **Step 7: S9: lock held on recover** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

````text
kubectl --context cluster-b create job --from=cronjob/nas-sync-manifest recover -n ea-pmc
```
````

Replace with:

````text
kubectl --context cluster-b create job --from=cronjob/nas-sync-manifest recover -n ea-pmc
# Failed with "lock … held" (exit 75)? A run is already in progress — let it finish (guide §13).
```
````

- [ ] **Step 8: S11: v3.15 → v3.16 pointer** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

```text
**Upgrading v3.14 → v3.15 specifically:** see the migration appendix at the end of the guide.
```

Replace with:

```text
**Upgrading v3.14 → v3.15 specifically:** see the migration appendix at the end of the guide.

**Upgrading v3.15 → v3.16:** let in-flight `nas-sync-manifest` / `nas-sync-chunks` Jobs finish
before applying the new CronJobs (a v3.15 generator takes no lock), then follow the order above.
Details: the guide's appendix "Also required when coming from v3.15 → v3.16".
```

- [ ] **Step 9: S12: two triage rows** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

```text
| `falling back to top-level split` | Chunks missing/stale | Harmless; guide §13 "Chunks stale" |
```

Replace with:

```text
| `falling back to top-level split` | Chunks missing/stale | Harmless; guide §13 "Chunks stale" |
| Generator Job `Failed`: `lock '…' held by […]` (exit 75) | Overlapping run of the same generator | guide §13 "lock … held"; wait, then re-run |
| `last-run` ends in `interrupted=TERM` | Pod stopped mid-sync | guide §13 "Status shows interrupted=TERM" |
```

- [ ] **Step 10: Related documents** — `docs/nas-sync-operations-runbook.md`

Find (occurs exactly once):

```text
- `cross-cluster-rsync-guide-v3.15-consolidated.md` — the reference: every file and flag
```

Replace with:

```text
- `cross-cluster-rsync-guide-v3.16-consolidated.md` — the reference: every file and flag
- `docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md` — the v3.16 findings, evidence and fixes
- `scripts/test-guide-behavior.sh` — runtime suite: runs the guide's scripts against a real rsync daemon
```

- [ ] **Step 11: File table: v3.16 authoritative** — `CLAUDE.md`

Find (occurs exactly once):

```text
| `cross-cluster-rsync-guide-v3.15-consolidated.md` | **Authoritative reference.** Every script, Dockerfile, and K8s/Istio manifest for both clusters, plus verify/troubleshooting steps. Consolidates v3.4–v3.14 and adds the v3.15 hardening + defect fixes. |
```

Replace with:

```text
| `cross-cluster-rsync-guide-v3.16-consolidated.md` | **Authoritative reference.** Every script, Dockerfile, and K8s/Istio manifest for both clusters, plus verify/troubleshooting steps. Consolidates v3.4–v3.15 and adds the v3.16 fixes (chunk generations, generator lock, any-character folder names, graceful SIGTERM). |
```

- [ ] **Step 12: File table: behavior suite + history** — `CLAUDE.md`

Find (occurs exactly once):

```text
| `scripts/check-guide.sh` | Consistency harness for the guide. **Run before every commit that touches a guide.** |
| `cross-cluster-rsync-guide-v3.14-consolidated.md`, `...v3.13...` | History. Do not edit; do not deploy from. |
```

Replace with:

```text
| `scripts/check-guide.sh` | Consistency harness for the guide. **Run before every commit that touches a guide.** |
| `scripts/test-guide-behavior.sh` | Runtime suite: extracts the guide's scripts and runs them against a real rsync daemon (tini as PID 1, cron). **Run before every commit that changes a script block.** |
| `docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md` | **Why v3.16 changed what it changed.** Every finding with its reproduction, and the design of each fix. |
| `cross-cluster-rsync-guide-v3.15-consolidated.md`, `...v3.14...`, `...v3.13...` | History. Do not edit; do not deploy from. |
```

- [ ] **Step 13: Non-obvious decisions: five v3.16 bullets** — `CLAUDE.md`

Find (occurs exactly once):

```text
- ConfigMaps/Secrets are mounted via `subPath` (single-file mounts) so they don't clobber the directory; read-only mounts are never `chmod`-ed.
```

Replace with:

```text
- ConfigMaps/Secrets are mounted via `subPath` (single-file mounts) so they don't clobber the directory; read-only mounts are never `chmod`-ed.
- **One place signals; every parent waits.** The CronJob wrapper (`§8.6`) and the Deployment entrypoint (`§8.7`) send SIGTERM to the sync's process group; the dispatcher and mode scripts only wait. If any shell exits before its children, tini (PID 1) exits and the kernel SIGKILLs rsync mid-file, leaving a `.<name>.XXXXXX` temp file that no run ever removes. Never `exec` the mode script from the dispatcher (the status write must run after it), and never `exec cron` in the Deployment entrypoint (cron jobs live in their own sessions, out of reach of `tini -g`).
- **Chunk files are named by generation** (`chunk-<gen>-NNN.txt`). rsync re-resolves each file by path while sending, so a fetch that overlaps the server's swap would otherwise mix two generations with rc=0. Never go back to fixed chunk names.
- **Generators are serialized by an NFS `mkdir` lock with a heartbeat** (`§4.7`), not by `concurrencyPolicy: Forbid` (which manual `create job --from` runs bypass) and not by `flock` (node-local on a `nolock` mount). A held lock exits 75.
- **Top-level folder names go through `--files-from --from0`, never into a remote path.** The rsync daemon glob-expands remote paths (`a[1]/` is served from `a1/`), `--list-only` escapes non-ASCII as `\#ooo` unless `-8`, and names may contain spaces, quotes or newlines. `list_top_dirs` (`§8.11`) is the only parser — do not reintroduce `awk '{print $NF}'`.
- **`-a` implies `-r`.** Any "top level only" rsync needs `--no-recursive --dirs`; `-a --dirs` silently copies the whole tree.
```

- [ ] **Step 14: Commands: two local test suites** — `CLAUDE.md`

Find (occurs exactly once):

```text
There is nothing to build or test locally, with one exception: **the guide checker**.
```

Replace with:

```text
There is nothing to build locally. There are two test suites: **the guide checker** (static) and **the behavior suite** (runtime).
```

- [ ] **Step 15: Commands: behavior suite usage** — `CLAUDE.md`

Find (occurs exactly once):

````text
bash scripts/check-guide.sh <guide.md>           # a specific one
```
````

Replace with:

````text
bash scripts/check-guide.sh <guide.md>           # a specific one

# ALWAYS run after changing a script block — runs the scripts against a real rsync daemon
bash scripts/test-guide-behavior.sh              # in docker (default; works from Windows)
bash scripts/test-guide-behavior.sh --slow       # + the Deployment/cron case (~2 min more)
bash scripts/test-guide-behavior.sh --native     # disposable Linux container/CI only (needs root)
```
````

- [ ] **Step 16: Commands: checker covers v3.16** — `CLAUDE.md`

Find (occurs exactly once):

```text
and that each v3.15 defect fix is still present.
```

Replace with:

```text
and that each v3.15 and v3.16 defect fix is still present.
```

- [ ] **Step 17: Commands: image tags** — `CLAUDE.md`

Find (occurs exactly 2 times — replace **all 2**):

```text
:3.15 .
```

Replace with:

```text
:3.16 .
```

- [ ] **Step 18: When editing: run both suites** — `CLAUDE.md`

Find (occurs exactly once):

```text
- **Run `bash scripts/check-guide.sh` before committing.** It catches every item above.
```

Replace with:

```text
- **Run `bash scripts/check-guide.sh` before committing.** It catches every item above.
- **Run `bash scripts/test-guide-behavior.sh` when a script block changes.** Every case fails on v3.15 by design; on the current guide every case must pass.
```

- [ ] **Step 19: No stale references remain**

```bash
grep -n 'v3.15-consolidated' docs/nas-sync-operations-runbook.md CLAUDE.md
grep -c ':3.15' docs/nas-sync-operations-runbook.md CLAUDE.md
```

Expected:

```text
CLAUDE.md:17:| `cross-cluster-rsync-guide-v3.15-consolidated.md`, `...v3.14...`, `...v3.13...` | History. Do not edit; do not deploy from. |
docs/nas-sync-operations-runbook.md:0
CLAUDE.md:0
```

Only the "History" row in CLAUDE.md may still name v3.15.

- [ ] **Step 20: Commit**

```bash
git add docs/nas-sync-operations-runbook.md CLAUDE.md
git commit -m "runbook + CLAUDE.md: v3.16 references, lock-held procedures, new design decisions"
```

---
### Task 11: Final verification and push

**Files:** none changed.

- [ ] **Step 1: Full behavior suite on v3.16 — everything passes**

```bash
bash scripts/test-guide-behavior.sh --native --slow cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
```

Expected:

```text
All 37 checks passed
```


- [ ] **Step 2: Full behavior suite on v3.15 — the defects are still detected**

```bash
bash scripts/test-guide-behavior.sh --native --slow cross-cluster-rsync-guide-v3.15-consolidated.md | tail -1
```

Expected:

```text
31 check(s) FAILED, 6 passed
```


- [ ] **Step 3: Static checks on both guides**

```bash
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.16-consolidated.md | tail -1
bash scripts/check-guide.sh cross-cluster-rsync-guide-v3.15-consolidated.md | tail -1
```

Expected:

```text
All checks passed (0 warning(s))
All checks passed (1 warning(s))
```


- [ ] **Step 4: v3.15 is untouched**

```bash
git diff --stat origin/master -- cross-cluster-rsync-guide-v3.15-consolidated.md
```

Expected:

```text
(no output)
```


- [ ] **Step 5: Push**

```bash
git push -u origin claude/happy-allen-yex0g4
```

---

## Spec coverage

| Spec section | Task |
|---|---|
| §4.1 chunk generations — server / client | 5 / 3 |
| §4.2 lock library | 5 |
| §4.3 per-run names, atomic meta | 5 |
| §4.4 cross-job overlap note | 5 (§6.3 note) |
| §5.1 `list_top_dirs` | 3 |
| §5.2 parallel mode | 3 |
| §5.3 verify tier 2 | 4 |
| §6 signals — CronJob path / Deployment path | 6 / 7 |
| §6 `tini -g` documented as belt and braces | 7 (§8.8, §10B.1) |
| §7 error handling (exit 75, 143, retry, invariants) | 3, 5, 6 |
| §8 compatibility + migration step | 3 (legacy meta), 9 (appendix) |
| §9 guide integration (§13, §14, consolidation, appendix, runbook, CLAUDE.md) | 3, 5, 9, 10 |
| §10.1 `check-guide.sh` | 8 |
| §10.2 behavior suite | 2 |
