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
#   --native   run on THIS Linux host: needs root, rsync, tini, perl, unshare, nc, flock,
#              pgrep, comm, mount, mountpoint, timeout (+ cron for --slow). It writes
#              /userapp/scripts, /etc/cron.d/nas-sync and
#              /etc/environment (restored afterwards) — use a disposable container or CI.
#   --slow     add the `deploy` case (waits for a cron minute boundary, ~1-2 min).
#   --case X   run only case X (repeatable): names loose swap lock signal deploy
#              (deploy implies --slow). An unknown X exits 2; so does a requested case
#              that was skipped, or a run in which no check ran.
#   NGB_KEEP=1 keep the workspace (logs of every run) and print its path
#############################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOW=0; NATIVE=0; GUIDE=""; ONLY=()
CASES="names loose swap lock signal deploy"
ARGS=("$@")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --slow)   SLOW=1 ;;
        --native) NATIVE=1 ;;
        --case)   [ "$#" -ge 2 ] || { echo "--case needs a name (one of: $CASES)"; exit 2; }
                  shift
                  ok_case=0; for c in $CASES; do [ "$c" = "$1" ] && ok_case=1; done
                  [ "$ok_case" -eq 1 ] || { echo "unknown case: '$1' (valid: $CASES)"; exit 2; }
                  [ "$1" = deploy ] && SLOW=1
                  ONLY+=("$1") ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *)        GUIDE="$1" ;;
    esac
    shift
done

# ---------------------------------------------------------------- docker re-exec
if [ "$NATIVE" -eq 0 ]; then
    command -v docker >/dev/null 2>&1 \
        || { echo "docker not found. Install it, or use --native inside a disposable Linux container (root)."; exit 2; }
    HOST_DIR=$(cd "$REPO_ROOT" && { pwd -W 2>/dev/null || pwd; })
    MSYS_NO_PATHCONV=1 exec docker run --rm --privileged -e NGB_KEEP -v "${HOST_DIR}:/repo" -w /repo ubuntu:24.04 bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null && apt-get install -y -qq rsync tini perl cron procps util-linux \
            netcat-openbsd >/dev/null || { echo "apt-get failed"; exit 2; }
        exec bash scripts/test-guide-behavior.sh --native "$@"' _ "${ARGS[@]+"${ARGS[@]}"}"
fi

cd "$REPO_ROOT" || exit 2
[ -n "$GUIDE" ] || GUIDE=$(ls -1 cross-cluster-rsync-guide-v*.md | sort -V | tail -1)
[ -f "$GUIDE" ] || { echo "guide not found: $GUIDE"; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "--native needs root"; exit 2; }
for t in rsync tini perl unshare nc flock mountpoint pgrep comm mount timeout; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t"; exit 2; }
done

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }   # check "<label>" "<shell test>"
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- workspace + cleanup
T=$(mktemp -d /tmp/ngb.XXXXXX) || { echo "cannot create the workspace under /tmp (mktemp failed)"; exit 2; }
[ -n "$T" ] && [ -d "$T" ] || { echo "workspace directory missing: '$T'"; exit 2; }
chmod 755 "$T"
DAEMON_PID=""
HAD_USERAPP=0; [ -d /userapp ] && HAD_USERAPP=1
cp -a /etc/environment "$T/environment.bak" 2>/dev/null
SHIM_MARK="# ngb-rsync-shim"
cleanup() {
    [ -n "$T" ] || return 0
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    # Only mounts under "$T/", compared literally (no regex): an empty/odd $T must never match the host's mounts.
    awk -v t="$T" 'index($2, t "/") == 1 {print $2}' /proc/mounts | sort -r | while read -r m; do umount -l "$m"; done
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
    B5=$'big5-\xa7\xda'      # legacy Big5/MS950 bytes: NOT valid UTF-8 (a UTF-8 locale must not drop it)
    NAMES=( "My folder" "folder" "資料" "John's" "a[1]" "a1" "star*" "starX" " lead" $'tab\tin' $'nl\nx' "-n" "normal" "$B5" )
    for d in "${NAMES[@]}"; do mkdir -p "$T/src/$d"; printf 'content of <%s>\n' "$d" > "$T/src/$d/f.txt"; done
    echo loose > "$T/src/loose.txt"
    mkdir -p "$T/src/.nas-sync-state/clients/x" "$T/src/.git"
    echo state > "$T/src/.nas-sync-state/clients/x/sync-manifest.txt"; echo cfg > "$T/src/.git/config"
    DST=$(fresh_dst names)
    LOCAL_NAS_PATH="$DST" PARALLEL_WORKERS=3 timeout --kill-after=10 300 "$S/nas-sync-parallel.sh" > "$T/names.log" 2>&1
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

    LOCAL_NAS_PATH="$DST" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify0.log" 2>&1
    RC=$?
    check "verify tier 2 on an in-sync tree: exit 0, drift=0 (rc=$RC)" '[ "$RC" -eq 0 ] && grep -q "VERIFY RESULT .* drift=0 " "$T/verify0.log"'
    for d in "資料" "My folder" "a[1]"; do       # same size, same mtime, different bytes
        f="$DST/$d/f.txt"; [ -f "$f" ] || continue
        t=$(stat -c %Y "$f"); sz=$(stat -c %s "$f")
        head -c "$sz" /dev/zero | tr '\0' 'Z' > "$f"; touch -d "@$t" "$f"
    done
    LOCAL_NAS_PATH="$DST" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify1.log" 2>&1
    RC=$?
    DRIFT=$(sed -n 's/^VERIFY RESULT .* drift=\([0-9]*\) .*/\1/p' "$T/verify1.log")
    check "verify tier 2 detects silent corruption in '資料', 'My folder', 'a[1]' (drift=${DRIFT:-?}, rc=$RC)" '[ "$RC" -eq 1 ] && [ "${DRIFT:-0}" -eq 3 ]'

    # Same tree, UTF-8 locale (LANG=C.UTF-8 is a common addition to an image). Two traps for a
    # name that is not valid UTF-8: grep drops the line (a v3.16 lister with a grep stage skipped
    # the folder without any error), and bash 5.2 `read -d ''` loses the NEXT record after a name
    # ending in a UTF-8 lead byte (the Big5 fixture ends in 0xDA, so "folder" vanished). Every
    # folder is checked, not just the Big5 one, and the scripts must still exit 0.
    if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then
        DST2=$(fresh_dst names-utf8)
        LC_ALL=C.UTF-8 LOCAL_NAS_PATH="$DST2" PARALLEL_WORKERS=3 timeout --kill-after=10 300 "$S/nas-sync-parallel.sh" > "$T/names-utf8.log" 2>&1
        RC=$?
        MIS2=""
        for d in "${NAMES[@]}"; do
            [ "$(cat "$DST2/$d/f.txt" 2>/dev/null)" = "content of <$d>" ] || MIS2="$MIS2 $(printf '%q' "$d")"
        done
        check "every folder synced with its own content under a UTF-8 locale (incl. non-UTF-8 names)${MIS2:+ — wrong:$MIS2}$([ "$RC" -eq 0 ] || echo " (rc=$RC)")" \
            '[ "$RC" -eq 0 ] && [ -z "$MIS2" ]'

        # Verify tier 2 against that in-sync UTF-8 target, same locale: all N dirs must be listed,
        # read and checked (the run dies on a lost name, and the N-of-N log line must hold).
        NN=${#NAMES[@]}
        LC_ALL=C.UTF-8 LOCAL_NAS_PATH="$DST2" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-utf8.log" 2>&1
        RC=$?
        TIER2=$(sed -n 's/^.* - Tier 2: \([0-9]*\) of \([0-9]*\) top-level dirs in this slice$/\1 \2/p' "$T/verify-utf8.log")
        OK2=0; [ "$RC" -eq 0 ] && [ "$TIER2" = "$NN $NN" ] && grep -q "VERIFY RESULT .* drift=0 " "$T/verify-utf8.log" && OK2=1
        check "verify tier 2 under a UTF-8 locale lists all $NN top-level dirs (drift=0)$([ "$OK2" -eq 1 ] || echo " (rc=$RC, 'Tier 2: N of M' = '${TIER2:-none}')")" \
            '[ "$OK2" -eq 1 ]'
    else
        skip "UTF-8 sub-checks (parallel folder contents, verify tier 2): no C.UTF-8 / C.utf8 locale in 'locale -a'"
    fi
fi

# ================================================================ loose
if want loose; then
    head2 "loose — the top-level pass owns the top level only (§8.3)"
    fresh_src
    mkdir -p "$T/src/deep/inner"; echo x > "$T/src/deep/inner/file"; echo top > "$T/src/top.txt"
    DST=$(fresh_dst loose)
    # xargs that dispatches nothing: whatever reaches the target came from the top-level pass.
    mkdir -p "$T/noxargs"; printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$T/noxargs/xargs"; chmod +x "$T/noxargs/xargs"
    PATH="$T/noxargs:$PATH" LOCAL_NAS_PATH="$DST" timeout --kill-after=10 300 "$S/nas-sync-parallel.sh" > "$T/loose.log" 2>&1
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
    timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/gen1.log" 2>&1
    check "generation 1 published" '[ -f "$STATE_DIR/common/chunks/chunks.meta" ]'
    for d in $(seq -w 1 300); do echo new > "$T/src/d$d/new-$d"; done      # shifts every round-robin slot
    sleep 1                                                                  # distinct generation id
    DST=$(fresh_dst swap)
    shim_set 60 "/common/chunks/"                                            # ~60 KB/s chunk fetch
    PATH="$T/shim:$PATH" LOCAL_NAS_PATH="$DST" timeout --kill-after=10 300 "$S/nas-sync-parallel.sh" > "$T/swap.log" 2>&1 &
    CPID=$!
    for _ in $(seq 1 100); do
        ls -A /tmp/nas-sync-parallel.*/chunks/ 2>/dev/null | grep -q . && break; sleep 0.1
    done
    sleep 1
    timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/gen2.log" 2>&1                            # swap mid-fetch
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
    timeout --kill-after=10 300 "$S/generate-manifests.sh" > /dev/null 2>&1; sort "$M" > "$T/m.base"
    timeout --kill-after=10 300 "$S/generate-chunks.sh" > /dev/null 2>&1; cat "$STATE_DIR"/common/chunks/chunk-*.txt | sort > "$T/c.base"
    check "lock: solo baselines are non-empty" '[ -s "$T/m.base" ] && [ -s "$T/c.base" ]'
    rm -rf "$STATE_DIR"
    # A throttled find makes each walk take a few seconds (stands in for 7.4M paths on NFS).
    mkdir -p "$T/slowfind"
    printf '#!/bin/bash\n/usr/bin/find "$@" | awk '"'"'{print; fflush()} NR%%2000==0{system("sleep 0.3")}'"'"'\n' > "$T/slowfind/find"
    chmod +x "$T/slowfind/find"
    for job in manifests chunks; do
        [ "$job" = manifests ] && GEN="$S/generate-manifests.sh" || GEN="$S/generate-chunks.sh"
        PATH="$T/slowfind:$PATH" timeout --kill-after=10 300 "$GEN" > "$T/$job.a.log" 2>&1 & APID=$!
        sleep 1.5
        PATH="$T/slowfind:$PATH" timeout --kill-after=10 300 "$GEN" > "$T/$job.b.log" 2>&1; RCB=$?
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
    timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/stale.log" 2>&1; RC=$?
    check "stale lock (heartbeat 20 min old) is broken and the run proceeds (rc=$RC)" '[ "$RC" -eq 0 ] && grep -q "stale" "$T/stale.log"'

    # Fail closed: a fresh lock whose age cannot be measured (the NAS-clock probe cannot be created,
    # e.g. a full or over-quota volume) must be treated as held, never as stale.
    REAL_TOUCH=$(command -v touch)
    mkdir -p "$T/notouch" "$STATE_DIR/locks/chunks.lock"
    printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *.probe.*) exit 1;; esac; done\nexec %s "$@"\n' "$REAL_TOUCH" > "$T/notouch/touch"
    chmod +x "$T/notouch/touch"
    printf 'run_id=live-holder\n' > "$STATE_DIR/locks/chunks.lock/owner"
    "$REAL_TOUCH" "$STATE_DIR/locks/chunks.lock/heartbeat"
    PATH="$T/notouch:$PATH" timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/nomeasure.log" 2>&1; RC=$?
    check "live lock is not broken when its age cannot be measured (exit 75) [rc=$RC]" \
        '[ "$RC" -eq 75 ] && grep -qx "run_id=live-holder" "$STATE_DIR/locks/chunks.lock/owner" 2>/dev/null && grep -q "cannot determine the age" "$T/nomeasure.log"'
    rm -rf "$STATE_DIR/locks/chunks.lock"

    # The heartbeat must survive a transient touch error. LOCK_HEARTBEAT=1 and the throttled find (a walk
    # of a few seconds); the shim touch fails exactly once, on the first REFRESH of an existing
    # .../heartbeat (the initial touch creates the file and passes). Sampled >= 2.5 s after the lock was
    # taken, the heartbeat must be newer than acquisition + 1 s: the loop went on after the failure.
    mkdir -p "$T/hbtouch"
    printf '#!/bin/bash\nfor a in "$@"; do case "$a" in */heartbeat)\n  if [ -e "$a" ] && [ ! -e "%s/hb.failed" ]; then : > "%s/hb.failed"; exit 1; fi;;\nesac; done\nexec %s "$@"\n' \
        "$T" "$T" "$REAL_TOUCH" > "$T/hbtouch/touch"
    chmod +x "$T/hbtouch/touch"
    rm -f "$T/hb.failed"
    LOCK_HEARTBEAT=1 PATH="$T/hbtouch:$T/slowfind:$PATH" timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/hb.log" 2>&1 & HPID=$!
    OWNER_F="$STATE_DIR/locks/chunks.lock/owner"
    for _ in $(seq 1 100); do [ -e "$OWNER_F" ] && break; sleep 0.05; done
    ACQ=$(stat -c %.3Y "$OWNER_F" 2>/dev/null || echo 0)                     # lock acquisition time (NAS clock)
    until awk -v a="$ACQ" -v n="$(date +%s.%N)" 'BEGIN{exit !(n >= a + 2.5)}'; do sleep 0.05; done
    HB=$(stat -c %.3Y "$STATE_DIR/locks/chunks.lock/heartbeat" 2>/dev/null || echo 0)
    wait "$HPID"; RC=$?
    check "heartbeat keeps running after a failed touch [rc=$RC, acquired=$ACQ, heartbeat=$HB]" \
        '[ "$RC" -eq 0 ] && [ -e "$T/hb.failed" ] && awk -v a="$ACQ" -v h="$HB" "BEGIN{exit !(a > 0 && h > a + 1)}" && grep -q "lock heartbeat touch failed" "$T/hb.log"'
    unset SOURCE_PATH STATE_DIR REGISTRY_FILE CHUNK_COUNT
fi

# ================================================================ signal
# Start the container command under tini as PID 1 of a fresh PID namespace, wait until rsync is
# mid-file, SIGTERM PID 1 (what kubelet does), and inspect the target.
# SIG_AFTER=<seconds> (set in the caller's environment) sends the SIGTERM that long after the start
# instead, for a signal that must land before rsync runs; no partial file is expected then.
sigterm_run() {  # sigterm_run <label> <dst> <logfile> <tini flags> -- command...
    local label="$1" dst="$2" log="$3" tf="$4"; shift 5
    unshare --pid --fork --mount-proc tini $tf -- "$@" > "$log" 2>&1 &
    local u=$! i tpid t0 t1
    if [ -n "${SIG_AFTER:-}" ]; then
        sleep "$SIG_AFTER"
    else
        for i in $(seq 1 900); do
            find "$dst" -name '.blob*' -type f 2>/dev/null | grep -q . && break; sleep 0.1
        done
        sleep 1
    fi
    tpid=$(pgrep -P "$u" -x tini | head -n 1)
    if [ -z "$tpid" ]; then
        bad "$label: container did not start (no tini found)"
        kill -KILL "$u" 2>/dev/null
        return 0
    fi
    t0=$(date +%s)
    kill -TERM "$tpid"
    for i in $(seq 1 600); do kill -0 "$u" 2>/dev/null || break; sleep 0.1; done
    t1=$(date +%s)
    if kill -0 "$u" 2>/dev/null; then
        # PID 1 of the namespace ignored SIGTERM: SIGKILL it (the kernel then kills everything
        # inside the namespace), then the unshare process.
        kill -KILL "$tpid" 2>/dev/null; kill -KILL "$u" 2>/dev/null
        echo "(killed after 60s)" >> "$log"
    fi
    local orphans partials took=$(( t1 - t0 ))
    # Parallel runs have more units than workers: queued units must be skipped, not started.
    check "$label: stopped within 15 s of SIGTERM (took ${took}s)" '[ "$took" -le 15 ]'
    orphans=$(find "$dst" -name '.blob*' -type f ! -path '*/.rsync-partial/*' | wc -l)
    partials=$(find "$dst" -path '*/.rsync-partial/*' -type f | wc -l)
    check "$label: no orphan .<file>.XXXXXX temp file left in the target (found $orphans)" '[ "$orphans" -eq 0 ]'
    [ -n "${SIG_AFTER:-}" ] || check "$label: interrupted file kept in .rsync-partial/ (found $partials)" '[ "$partials" -ge 1 ]'
    check "$label: status file records the interruption" 'grep -q "interrupted=TERM" "$dst/.nas-sync-status/last-run" 2>/dev/null'
}

if want signal; then
    head2 "signal — SIGTERM to PID 1 on the CronJob path (§8.5, §8.6, mode scripts)"
    fresh_src
    # 4 big folders with PARALLEL_WORKERS=2: two units run, two are queued when SIGTERM arrives.
    for d in big big2 big3 big4; do
        mkdir -p "$T/src/$d"; head -c 40000000 /dev/urandom > "$T/src/$d/blob-$d.bin"
    done
    shim_set 4000                                                         # ~4 MB/s → ~10 s per file
    for tf in "-g" ""; do
        for mode in standard parallel; do
            DST=$(fresh_dst "sig-${mode}${tf}")
            PATH="$T/shim:$PATH" SYNC_MODE=$mode LOCAL_NAS_PATH="$DST" PARALLEL_WORKERS=2 ISTIO_ADMIN_PORT=1 \
                sigterm_run "tini ${tf:-(no -g)} $mode" "$DST" "$T/sig-$mode$tf.log" "$tf" -- "$S/run-with-sidecar-quit.sh"
        done
    done
    # SIGTERM while the pre-flight is still running (a slow `mountpoint` on a stale NFS mount): the
    # signal only sets a flag, so the mode script must check it before it starts rsync. ~2 MB/s
    # keeps an rsync that wrongly starts running past the 60 s the helper waits, so it would be
    # SIGKILLed mid-file and leave its temp file behind. The SIGTERM comes 2 s in and the shim
    # lasts 6 s: the chain has 2 s to reach the shim, and the signal still lands 4 s before it ends.
    mkdir -p "$T/shim-mp"
    printf '%s\n' '#!/bin/bash' 'sleep 6' 'exit 0' > "$T/shim-mp/mountpoint"; chmod +x "$T/shim-mp/mountpoint"
    shim_set 2000
    DST=$(fresh_dst "sig-preflight")
    PATH="$T/shim-mp:$T/shim:$PATH" SYNC_MODE=standard LOCAL_NAS_PATH="$DST" ISTIO_ADMIN_PORT=1 SIG_AFTER=2 \
        sigterm_run "SIGTERM during pre-flight" "$DST" "$T/sig-preflight.log" "-g" -- "$S/run-with-sidecar-quit.sh"
    BLOBS=$(find "$DST" -name '.blob*' | wc -l)
    check "SIGTERM during pre-flight: rsync never started (no .blob* file in the target, found $BLOBS)" '[ "$BLOBS" -eq 0 ]'
    shim_off

    # The same stop, 25 times, in the fast-exit case. Under `tini -g` the dispatcher gets two TERMs within milliseconds
    # (tini's group TERM, then the wrapper's own `kill -TERM 0`) while its `wait` is running. When
    # the mode script exits at that same moment, wait_child has to keep a usable status: the
    # container must exit 143 and last-run must end with a well-formed
    # `exit=143 elapsed=<digits>s ... interrupted=TERM`, never `exit=-1`, exit 255 or an empty
    # elapsed. Each run: wrapper -> dispatcher -> standard mode, tini -g as PID 1.
    # The stall is the pre-flight RETRY SLEEP (REMOTE_PORT closed, PREFLIGHT_WAIT=30), not a slow
    # `mountpoint`: that runs under `timeout`, which gives it its own process group, so the group
    # TERM never reaches it and the mode script only exits when the shim ends, seconds after the
    # signals. A foreground `sleep` in the pre-flight does get the group TERM, so the mode script
    # exits within milliseconds of the two TERMs - the window the race needs (about a third of
    # the runs fail on a dispatcher without the v3.16 round-2 fixes: exit 255 from
    # `exit=-1`, or a negative elapsed because a late group TERM killed `date`).
    # SIGTERM goes in 1 s after the start.
    DST=$(fresh_dst "sig-loop")
    LOOP_N=25; LOOP_OK=0; LOOP_BAD=""
    for i in $(seq 1 "$LOOP_N"); do
        rm -rf "$DST/.nas-sync-status"
        SYNC_MODE=standard LOCAL_NAS_PATH="$DST" ISTIO_ADMIN_PORT=1 REMOTE_PORT=1 PREFLIGHT_RETRIES=5 PREFLIGHT_WAIT=30 \
            unshare --pid --fork --mount-proc tini -g -- "$S/run-with-sidecar-quit.sh" > "$T/sig-loop-$i.log" 2>&1 &
        u=$!
        sleep 1
        tpid=$(pgrep -P "$u" -x tini | head -n 1)
        [ -n "$tpid" ] && kill -TERM "$tpid"
        for _ in $(seq 1 200); do kill -0 "$u" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$u" 2>/dev/null; then
            kill -KILL "$tpid" 2>/dev/null; kill -KILL "$u" 2>/dev/null; echo "(killed after 20s)" >> "$T/sig-loop-$i.log"
        fi
        wait "$u" 2>/dev/null; loop_rc=$?
        if [ "$loop_rc" -eq 143 ] \
           && grep -Eq ' exit=143 elapsed=[0-9]+s .* interrupted=TERM$' "$DST/.nas-sync-status/last-run" 2>/dev/null; then
            LOOP_OK=$((LOOP_OK+1))
        else
            LOOP_BAD="$LOOP_BAD $i(rc=$loop_rc)"
        fi
    done
    check "SIGTERM during pre-flight, $LOOP_N runs under tini -g: $LOOP_OK/$LOOP_N runs exited 143 with a valid status line${LOOP_BAD:+ — failed:$LOOP_BAD}" \
        '[ "$LOOP_OK" -eq "$LOOP_N" ]'
fi

# ================================================================ deploy (--slow)
if [ "$SLOW" -eq 1 ] && want deploy; then
    head2 "deploy — SIGTERM to the Deployment entrypoint (§8.7)"
    if ! command -v cron >/dev/null 2>&1; then
        skip "cron not installed"
    elif pgrep -x cron >/dev/null 2>&1; then
        skip "a cron daemon is already running here — it would also execute /etc/cron.d/nas-sync"
    elif { [ -e /usr/local/bin/rsync ] || [ -L /usr/local/bin/rsync ]; } && ! grep -qs "$SHIM_MARK" /usr/local/bin/rsync; then
        skip "/usr/local/bin/rsync already exists and is not this suite's shim — refusing to overwrite it"
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
        shim_off
        grep -qs "$SHIM_MARK" /usr/local/bin/rsync && rm -f /usr/local/bin/rsync
        rm -f /etc/cron.d/nas-sync
    fi
fi

printf '\n'
[ "$SKIP" -gt 0 ] && printf '%d skipped. ' "$SKIP"
if [ $((PASS + FAIL)) -eq 0 ]; then
    echo "no checks ran"
    exit 2
fi
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31m%d check(s) FAILED\033[0m, %d passed\n' "$FAIL" "$PASS"
    exit 1
fi
printf '\033[32mAll %d checks passed\033[0m\n' "$PASS"
if [ "$SKIP" -gt 0 ] && [ "${#ONLY[@]}" -gt 0 ]; then
    echo "a case requested with --case was skipped: exit 2"
    exit 2
fi
exit 0
