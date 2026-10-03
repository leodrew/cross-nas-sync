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
#              pgrep, comm, mount, mountpoint, timeout (+ cron, and cc for one sub-case, for --slow). It writes
#              /userapp/scripts, /etc/cron.d/nas-sync and
#              /etc/environment (restored afterwards) — use a disposable container or CI.
#   --slow     add the `deploy` case (waits for two cron minute boundaries, ~2-3 min).
#   --case X   run only case X (repeatable): names build loose swap lock signal deploy
#              (deploy implies --slow). An unknown X exits 2; so does a requested case
#              that was skipped, even in part (`--case deploy` without cc), or a run in which
#              no check ran. Without --case, a skip is reported and the exit stays 0.
#   NGB_KEEP=1 keep the workspace (logs of every run) and print its path
#############################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOW=0; NATIVE=0; GUIDE=""; ONLY=()
CASES="names build loose swap lock signal deploy"
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
            netcat-openbsd gcc libc6-dev >/dev/null || { echo "apt-get failed"; exit 2; }
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
BG_PIDS=()      # background helpers a case starts (black-hole listener, fake sidecars): cleanup() kills what is left
bg_add() { BG_PIDS+=("$1"); }
bg_stop() {     # bg_stop <pid>: stop a helper registered with bg_add, reap it, and forget the PID (never reused by cleanup)
    local p="$1" q keep=()
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
    for q in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do [ "$q" = "$p" ] || keep+=("$q"); done
    BG_PIDS=(${keep[@]+"${keep[@]}"})
}
HAD_USERAPP=0; [ -d /userapp ] && HAD_USERAPP=1
cp -a /etc/environment "$T/environment.bak" 2>/dev/null
SHIM_MARK="# ngb-rsync-shim"
cleanup() {
    [ -n "$T" ] || return 0
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    local bp; for bp in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$bp" 2>/dev/null; done      # by recorded PID, never by name
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
bw=""; match=""; preload=""; stall_ms=""
[ -f /etc/ngb-rsync-shim.conf ] && . /etc/ngb-rsync-shim.conf
case " \$* " in *" --daemon "*|*" --list-only "*) exec $REAL_RSYNC "\$@" ;; esac
# Optional LD_PRELOAD (deploy case, slow cleanup). Set only below the --daemon/--list-only line:
# just the client rsync gets it, never the daemon.
[ -n "\$preload" ] && export LD_PRELOAD="\$preload" NGB_STALL_MS="\$stall_ms"
if [ -n "\$bw" ] && { [ -z "\$match" ] || [[ " \$* " == *"\$match"* ]]; }; then
    exec $REAL_RSYNC --bwlimit="\$bw" "\$@"
fi
exec $REAL_RSYNC "\$@"
EOF
chmod +x "$T/shim/rsync"
shim_set() {  # shim_set <bwlimit KB/s> [match] [LD_PRELOAD .so] [stall ms]
    printf 'bw=%s\nmatch=%s\npreload=%q\nstall_ms=%s\n' "$1" "${2:-}" "${3:-}" "${4:-}" > /etc/ngb-rsync-shim.conf
}
shim_off() { rm -f /etc/ngb-rsync-shim.conf; }

# date shim (deploy case, "SIGTERM right at start"). log() runs `date`, so holding ONE call parks the
# entrypoint at a known point. It holds the first call after "OK Cron configured" has reached the log
# (the test redirects 2>&1 into the log file, so this shell's fd 2 is that file; read it as /proc/$$/fd/2,
# because grep's own stderr is /dev/null): the one inside log "=== INITIAL SYNC …", where the TERM trap
# is installed and nothing is forked yet. NGB_HELD is a per-run marker, so only one call is held; the
# sleep ends early when the TERM (tini -g: the whole group) arrives. The marker holds the PARENT's
# command line, and the test requires it to name entrypoint-deployment: if log() ever stops forking
# `date`, this shim would hold the dispatcher's call instead, and the sub-case would pass vacuously.
mkdir -p "$T/shim-date"
cat > "$T/shim-date/date" <<EOF
#!/bin/bash
if grep -q 'OK Cron configured' /proc/\$\$/fd/2 2>/dev/null && [ ! -e "\$NGB_HELD" ]; then
    ps -o args= -p "\$PPID" > "\$NGB_HELD"; sleep 5
fi
exec $(command -v date) "\$@"
EOF
chmod +x "$T/shim-date/date"

fresh_src() { rm -rf "$T/src"; mkdir -p "$T/src"; }
free_port() {  # free_port <first> <last> → echoes the first port in the range nothing listens on
    local p
    for p in $(seq "$1" "$2"); do (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }; done
    return 1
}
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

    # log() is printf %()T since the final wave (a $(date) is aborted by a second trapped signal on bash 5.2): same format.
    check "log() lines keep the 'YYYY-MM-DD HH:MM:SS - ' format" \
        'grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} - === NAS SYNC \(parallel" "$T/names.log"'

    # A top-level listing that ends rc 24 (an entry vanished while it ran) is a success, like every other
    # rsync step (§8.3, §8.10). The shim reports rc 24 for every successful --list-only.
    mkdir -p "$T/shim-list24"
    printf '#!/bin/bash\ncase " $* " in *" --list-only "*) %s "$@"; rc=$?; [ "$rc" -eq 0 ] && exit 24; exit "$rc";; esac\nexec %s "$@"\n' \
        "$REAL_RSYNC" "$REAL_RSYNC" > "$T/shim-list24/rsync"
    chmod +x "$T/shim-list24/rsync"
    DST3=$(fresh_dst names-rc24)
    PATH="$T/shim-list24:$PATH" LOCAL_NAS_PATH="$DST3" PARALLEL_WORKERS=3 timeout --kill-after=10 300 "$S/nas-sync-parallel.sh" > "$T/names-rc24.log" 2>&1
    RC=$?
    MIS3=""
    for d in "${NAMES[@]}"; do
        [ "$(cat "$DST3/$d/f.txt" 2>/dev/null)" = "content of <$d>" ] || MIS3="$MIS3 $(printf '%q' "$d")"
    done
    check "parallel: a top-level listing that ends rc 24 is a success, every folder synced (rc=$RC)${MIS3:+ — wrong:$MIS3}" \
        '[ "$RC" -eq 0 ] && [ -z "$MIS3" ]'
    PATH="$T/shim-list24:$PATH" LOCAL_NAS_PATH="$DST3" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-rc24.log" 2>&1
    RC=$?
    check "verify tier 2: a top-level listing that ends rc 24 is a success, drift=0 (rc=$RC)" \
        '[ "$RC" -eq 0 ] && grep -q "VERIFY RESULT .* drift=0 " "$T/verify-rc24.log"'

    # A listing that ends rc 23 is NOT a success: an entry that still exists could not be read, so it is missing from
    # the list and nothing would ever sync (parallel) or check (verify) it. The shim drops the folder "normal" from
    # every --list-only output and exits 23. Both callers must fail loudly, as before the final wave.
    mkdir -p "$T/shim-list23"
    printf '#!/bin/bash\ncase " $* " in *" --list-only "*) %s "$@" | grep -v " normal$"; echo "rsync error: some files/attrs were not transferred (code 23) at main.c(1338) [sender=3.2.7]" >&2; exit 23;; esac\nexec %s "$@"\n' \
        "$REAL_RSYNC" "$REAL_RSYNC" > "$T/shim-list23/rsync"
    chmod +x "$T/shim-list23/rsync"
    DST5=$(fresh_dst names-rc23)
    PATH="$T/shim-list23:$PATH" LOCAL_NAS_PATH="$DST5" PARALLEL_WORKERS=3 timeout --kill-after=10 300 "$S/nas-sync-parallel.sh" > "$T/names-rc23.log" 2>&1
    RC=$?
    check "parallel: a top-level listing that ends rc 23 fails, it does not report success with a folder unsynced (rc=$RC)" \
        '[ "$RC" -ne 0 ] && grep -q "Cannot list top-level folders (rsync rc=23)" "$T/names-rc23.log" && ! grep -q "all OK" "$T/names-rc23.log"'
    # DST3 is in sync (rc 24 run above). Corrupt "normal" there (same size and mtime, other bytes): only a listing that
    # names it can catch that, so a verify that carries on with the short list reports drift=0.
    f="$DST3/normal/f.txt"; t=$(stat -c %Y "$f"); sz=$(stat -c %s "$f")
    head -c "$sz" /dev/zero | tr '\0' 'Z' > "$f"; touch -d "@$t" "$f"
    PATH="$T/shim-list23:$PATH" LOCAL_NAS_PATH="$DST3" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-rc23.log" 2>&1
    RC=$?
    check "verify tier 2: a top-level listing that ends rc 23 fails (exit 23), it does not report drift=0 / VERIFY OK (rc=$RC)" \
        '[ "$RC" -eq 23 ] && grep -q "Tier 2: cannot list top-level dirs (rsync rc=23)" "$T/verify-rc23.log" && ! grep -q "VERIFY OK" "$T/verify-rc23.log"'

    # An unreadable source DIRECTORY is rc 23 too ("opendir ... Permission denied"; an I/O error looks the same). Nothing
    # inside it is listed, compared or counted, so a verify that tolerated rc 23 said drift=0 / VERIFY OK over a tree it
    # had not read: in silence in tier 1, with a misleading WARN in tier 2. The suite's daemon runs as root and reads
    # everything, so a second daemon runs as `nobody` over a tree with a root-owned mode-700 directory, which is the rc 23
    # a daemon gives under NFS root_squash. No shim: the error comes from rsync itself.
    NB_UID=$(id -u nobody 2>/dev/null); NB_GID=$(id -g nobody 2>/dev/null)
    if [ -z "$NB_UID" ] || [ -z "$NB_GID" ]; then
        skip "verify, unreadable source directory (tier 1 and 2): no user 'nobody' to run the second daemon as"
    else
        mkdir -p "$T/src-nb/ok" "$T/src-nb/locked"
        echo okdata > "$T/src-nb/ok/a.txt"; echo SECRET > "$T/src-nb/locked/secret.txt"; echo top > "$T/src-nb/top.txt"
        chmod 755 "$T/src-nb" "$T/src-nb/ok"          # explicit modes: nothing may depend on the caller's umask
        chmod 644 "$T/src-nb/top.txt" "$T/src-nb/ok/a.txt" "$T/src-nb/locked/secret.txt"
        cat > "$T/rsyncd-nb.conf" <<EOF
uid = $NB_UID
gid = $NB_GID
use chroot = no
reverse lookup = no
pid file = $T/rsyncd-nb.pid
log file = $T/rsyncd-nb.log
[nas-data]
    path = $T/src-nb
    read only = yes
    list = yes
    auth users = syncuser
    secrets file = $T/rsyncd.secrets
EOF
        NBPORT=$(free_port 19000 19090)
        "$REAL_RSYNC" --daemon --no-detach --config="$T/rsyncd-nb.conf" --port="$NBPORT" --address=127.0.0.1 & NBPID=$!; bg_add "$NBPID"
        for _ in $(seq 1 50); do nc -z 127.0.0.1 "$NBPORT" 2>/dev/null && break; sleep 0.1; done
        DSTN=$(fresh_dst names-nb)
        "$REAL_RSYNC" -a "$T/src-nb/" "$DSTN/"
        vnb() {  # vnb <VERIFY_MODE> <logfile>: verify the tree $DSTN against the daemon that runs as nobody
            REMOTE_PORT="$NBPORT" LOCAL_NAS_PATH="$DSTN" VERIFY_MODE="$1" VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$2" 2>&1
        }
        # Controls: everything readable. The setup must show a clean tree as clean and a missing file as drift, or the
        # failures below would not prove anything about the unreadable directory.
        chmod 755 "$T/src-nb/locked"
        vnb meta "$T/nb-c1m.log"; RC1=$?; vnb checksum "$T/nb-c1c.log"; RC2=$?
        check "control (daemon as nobody, all readable, tree in sync): verify tier 1 and tier 2 exit 0, drift=0 (rc=$RC1/$RC2)" \
            '[ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && grep -q "VERIFY RESULT .* drift=0 " "$T/nb-c1m.log" && grep -q "VERIFY RESULT .* drift=0 " "$T/nb-c1c.log"'
        rm -f "$DSTN/locked/secret.txt"            # real drift, inside the directory that is about to become unreadable
        vnb meta "$T/nb-c2m.log"; RC1=$?; vnb checksum "$T/nb-c2c.log"; RC2=$?
        check "control (all readable): the file missing in 'locked' is drift=1 in tier 1 and in tier 2 (exit 1/1, rc=$RC1/$RC2)" \
            '[ "$RC1" -eq 1 ] && [ "$RC2" -eq 1 ] && grep -q "VERIFY RESULT .* drift=1 " "$T/nb-c2m.log" && grep -q "VERIFY RESULT .* drift=1 " "$T/nb-c2c.log"'
        chmod 700 "$T/src-nb/locked"               # root-owned, mode 700: the daemon (nobody) cannot read it
        vnb meta "$T/nb-m.log"; RCM=$?
        check "verify tier 1: a source directory the daemon cannot read fails the run (exit 23), no drift=0 / VERIFY OK (rc=$RCM)" \
            '[ "$RCM" -eq 23 ] && grep -q "rsync failed during metadata verify (rc=23)" "$T/nb-m.log" && grep -q "opendir \"locked\"" "$T/nb-m.log" && ! grep -q "VERIFY OK" "$T/nb-m.log" && ! grep -q "VERIFY RESULT" "$T/nb-m.log"'
        vnb checksum "$T/nb-c.log"; RCC=$?
        check "verify tier 2: a source directory the daemon cannot read fails the run (exit 23) and names the folder (rc=$RCC)" \
            '[ "$RCC" -eq 23 ] && grep -q "rc=23 checking locked: part of it could not be read" "$T/nb-c.log" && grep -q "opendir \"locked\"" "$T/nb-c.log" && ! grep -q "VERIFY OK" "$T/nb-c.log" && ! grep -q "VERIFY RESULT" "$T/nb-c.log"'
        bg_stop "$NBPID"
    fi

    # The benign rc 23 stays tolerated: a folder that VANISHES between the listing and its check. rsync then reports only
    # `link_stat "<d>" ... No such file or directory`. The shim removes the folder right after the --list-only run (a real
    # removal, so the check really finds nothing). "removed between listing and checking" is in the WARN of both the
    # old and the new text, so this check is green on either and only guards against a regression.
    mkdir -p "$T/shim-vanish"
    printf '#!/bin/bash\ncase " $* " in *" --list-only "*) %s "$@"; rc=$?; rm -rf "%s/src/vanishing"; exit "$rc";; esac\nexec %s "$@"\n' \
        "$REAL_RSYNC" "$T" "$REAL_RSYNC" > "$T/shim-vanish/rsync"
    chmod +x "$T/shim-vanish/rsync"
    DST6=$(fresh_dst names-vanish)
    mkdir -p "$T/src/vanishing"; echo v > "$T/src/vanishing/f.txt"
    "$REAL_RSYNC" -a "$T/src/" "$DST6/"
    PATH="$T/shim-vanish:$PATH" LOCAL_NAS_PATH="$DST6" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-vanish.log" 2>&1
    RC=$?
    check "verify tier 2: a folder that vanishes between the listing and its check is tolerated (WARN, exit 0, drift=0) (rc=$RC)" \
        '[ "$RC" -eq 0 ] && [ ! -e "$T/src/vanishing" ] && grep -q "removed between listing and checking" "$T/verify-vanish.log" && grep -q "VERIFY RESULT .* drift=0 " "$T/verify-vanish.log"'
    # ... and real drift in another folder is still counted exactly once: the rsync error text goes to a separate file
    # and is never counted as drift.
    mkdir -p "$T/src/vanishing"; echo v > "$T/src/vanishing/f.txt"
    f="$DST6/normal/f.txt"; t=$(stat -c %Y "$f"); sz=$(stat -c %s "$f")
    head -c "$sz" /dev/zero | tr '\0' 'Z' > "$f"; touch -d "@$t" "$f"
    PATH="$T/shim-vanish:$PATH" LOCAL_NAS_PATH="$DST6" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-vanish2.log" 2>&1
    RC=$?
    check "verify tier 2: with a vanished folder, real drift elsewhere is counted exactly (exit 1, drift=1, rc=$RC)" \
        '[ "$RC" -eq 1 ] && [ ! -e "$T/src/vanishing" ] && grep -q "VERIFY RESULT .* drift=1 " "$T/verify-vanish2.log" && ! grep -q "verify aborted" "$T/verify-vanish2.log"'

    # VERIFY_SLICES with a leading zero: $(( )) reads 08 as an arithmetic error that skipped tier 2 altogether and still
    # ended in VERIFY OK, and 010 as octal 8. A non-number (or 0) was the same silent skip. DST8 is in sync.
    DST8=$(fresh_dst names-slices)
    "$REAL_RSYNC" -a "$T/src/" "$DST8/"
    for sl in 08 010; do
        want=$((10#$sl))
        LOCAL_NAS_PATH="$DST8" VERIFY_MODE=checksum VERIFY_SLICES="$sl" timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-slices-$sl.log" 2>&1
        RC=$?
        check "VERIFY_SLICES=$sl (leading zero) is decimal $want: tier 2 runs as 'slice N of $want', no arithmetic error, exit 0 (rc=$RC)" \
            '[ "$RC" -eq 0 ] && grep -Eq "Tier 2: checksum verify, slice [0-9]+ of $want \(week" "$T/verify-slices-$sl.log" && grep -q "Tier 2: drift=0 of" "$T/verify-slices-$sl.log" && ! grep -qiE "too great|arithmetic|syntax error" "$T/verify-slices-$sl.log"'
    done
    for sl in abc 0; do
        LOCAL_NAS_PATH="$DST8" VERIFY_MODE=checksum VERIFY_SLICES="$sl" timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-slices-$sl.log" 2>&1
        RC=$?
        check "VERIFY_SLICES=$sl: verify fails with 'not a positive integer' instead of skipping tier 2 and saying VERIFY OK (rc=$RC)" \
            '[ "$RC" -ne 0 ] && grep -q "VERIFY_SLICES=.$sl. is not a positive integer" "$T/verify-slices-$sl.log" && ! grep -q "VERIFY OK" "$T/verify-slices-$sl.log"'
    done
    # The other settings that decide what verify compares are checked up front too, before tier 1 runs for hours:
    # an unknown VERIFY_MODE ran no tier and said VERIFY OK; a non-numeric VERIFY_FAIL_THRESHOLD turned the final
    # comparison into an error (false), so real drift also ended in VERIFY OK.
    LOCAL_NAS_PATH="$DST8" VERIFY_MODE=Both VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-mode-bad.log" 2>&1
    RC=$?
    check "VERIFY_MODE=Both: verify fails ('is not meta, checksum or both') instead of running no tier and saying VERIFY OK (rc=$RC)" \
        '[ "$RC" -ne 0 ] && grep -q "VERIFY_MODE=.Both. is not meta, checksum or both" "$T/verify-mode-bad.log" && ! grep -q "VERIFY OK" "$T/verify-mode-bad.log"'
    LOCAL_NAS_PATH="$DST8" VERIFY_MODE=meta VERIFY_FAIL_THRESHOLD=abc timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-thr-bad.log" 2>&1
    RC=$?
    check "VERIFY_FAIL_THRESHOLD=abc: verify fails ('not a non-negative integer') instead of saying VERIFY OK (rc=$RC)" \
        '[ "$RC" -ne 0 ] && grep -q "VERIFY_FAIL_THRESHOLD=.abc. is not a non-negative integer" "$T/verify-thr-bad.log" && ! grep -q "VERIFY OK" "$T/verify-thr-bad.log"'
    LOCAL_NAS_PATH="$DST8" VERIFY_MODE=both VERIFY_SLICES=abc timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-both-slices-bad.log" 2>&1
    RC=$?
    check "VERIFY_MODE=both with VERIFY_SLICES=abc fails before tier 1 starts (rc=$RC)" \
        '[ "$RC" -ne 0 ] && grep -q "VERIFY_SLICES=.abc. is not a positive integer" "$T/verify-both-slices-bad.log" && ! grep -q "Tier 1:" "$T/verify-both-slices-bad.log"'
    # Tier 2 tolerates rc 23 only when rsync explains it with a "vanished" line. An rc 23 that carries only the
    # summary line ("rsync error: … (code 23)") explains nothing and must fail. The shim does that for the
    # per-folder checksum pass only.
    mkdir -p "$T/shim-ck23"
    printf '#!/bin/bash
case " $* " in *" --list-only "*) exec %s "$@";; *" --checksum "*) %s "$@"; echo "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338) [generator=3.2.7]" >&2; exit 23;; esac
exec %s "$@"
' \
        "$REAL_RSYNC" "$REAL_RSYNC" "$REAL_RSYNC" > "$T/shim-ck23/rsync"
    chmod +x "$T/shim-ck23/rsync"
    PATH="$T/shim-ck23:$PATH" LOCAL_NAS_PATH="$DST8" VERIFY_MODE=checksum VERIFY_SLICES=1 timeout --kill-after=10 300 "$S/nas-sync-verify.sh" > "$T/verify-ck23-bare.log" 2>&1
    RC=$?
    check "verify tier 2: an rc 23 with no 'vanished' line fails (exit 23), it is not tolerated as a removed folder (rc=$RC)" \
        '[ "$RC" -eq 23 ] && ! grep -q "VERIFY OK" "$T/verify-ck23-bare.log" && ! grep -q "removed between listing and checking" "$T/verify-ck23-bare.log"'

    # A daemon that accepts the connection and never answers: the chunk-list fetch and the top-level listing
    # must give up after RSYNC_LIST_TIMEOUT (rsync --timeout) instead of hanging until the Job deadline.
    cat > "$T/blackhole.pl" <<'PEOF'
use IO::Socket::INET;
my ($port) = @ARGV;
my $l = IO::Socket::INET->new(Listen => 20, LocalAddr => '127.0.0.1', LocalPort => $port, ReuseAddr => 1) or die "listen: $!";
my @keep;
while (my $c = $l->accept) { push @keep, $c; }   # accept, never answer, never close
PEOF
    BHPORT=$(free_port 18900 18990)
    perl "$T/blackhole.pl" "$BHPORT" & BHPID=$!; bg_add "$BHPID"
    for _ in $(seq 1 50); do nc -z 127.0.0.1 "$BHPORT" 2>/dev/null && break; sleep 0.1; done
    DST4=$(fresh_dst names-stall)
    t0=$(date +%s)
    REMOTE_PORT="$BHPORT" RSYNC_LIST_TIMEOUT=2 LOCAL_NAS_PATH="$DST4" timeout --kill-after=5 40 "$S/nas-sync-parallel.sh" > "$T/names-stall.log" 2>&1
    RC=$?
    took=$(( $(date +%s) - t0 ))
    bg_stop "$BHPID"
    check "stalled daemon: chunk fetch and top-level listing time out (took ${took}s, rc=$RC)" \
        '[ "$RC" -eq 1 ] && [ "$took" -lt 30 ] && grep -Eq "No chunk lists available \(rc=3[05]\)" "$T/names-stall.log" && grep -Eq "Cannot list top-level folders \(rsync rc=3[05]\)" "$T/names-stall.log"'
fi

# ================================================================ build
if want build; then
    head2 "build — the Dockerfiles' CRLF guard under dash (§4.4, §8.8)"
    # `docker build` runs a RUN line with /bin/sh -c, which is dash on ubuntu:24.04. The guard must FAIL the build on a
    # CRLF script. v3.12-v3.15 grepped for $'\r', which dash reads as the literal text $\r: it never matched, so the
    # guard never fired. Each RUN line is taken from the guide, its continuations joined as docker does, its image paths
    # pointed at a scratch dir, and run with dash explicitly: under a bash /bin/sh that old guard fires too, so a
    # regression would go unnoticed.
    DASH=$(command -v dash) || DASH=""
    if [ -z "$DASH" ]; then
        skip "build: dash is not installed (apt-get install dash) - the guard has to be proven under dash, the shell of the image build, not under a bash /bin/sh"
    else
    for sec in 4.4 8.8; do
        run=$(awk -v h="### $sec File:" 'index($0,h)==1{f=1;next} f&&/^```dockerfile/{p=1;next} p&&/^```/{exit} p&&/^RUN for f in/{r=1} p&&r{print} p&&r&&!/\\$/{exit}' "$GUIDE" | tr -d '\r')
        if [ -z "$run" ]; then bad "§$sec: no 'RUN for f in …' CRLF guard found in the Dockerfile block"; continue; fi
        W="$T/build-$sec"; rm -rf "$W"; mkdir -p "$W/userapp/scripts"
        cmd=$(printf '%s\n' "$run" | sed -e ':a;/\\$/{N;s/\\\n//;ba}' -e 's/^RUN //' \
              | sed "s#/entrypoint.sh#$W/entrypoint.sh#g; s#/userapp/scripts/#$W/userapp/scripts/#g")
        for f in entrypoint.sh userapp/scripts/generate-manifests.sh userapp/scripts/generate-chunks.sh userapp/scripts/nas-sync-state-lock.sh userapp/scripts/other.sh; do
            printf '#!/bin/bash\necho hi\n' > "$W/$f"
        done
        "$DASH" -c "$cmd" > "$W/out0" 2>&1; RC0=$?
        check "§$sec guard: LF scripts pass the build (rc=$RC0)" '[ "$RC0" -eq 0 ]'
        printf '#!/bin/bash\r\necho hi\r\n' > "$W/userapp/scripts/nas-sync-state-lock.sh"       # CRLF, shebang included
        "$DASH" -c "$cmd" > "$W/out1" 2>&1; RC1=$?
        check "§$sec guard: a CRLF script FAILS the build under dash (rc=$RC1)" '[ "$RC1" -ne 0 ] && grep -q "ERROR: CRLF" "$W/out1"'
        printf '#!/bin/bash\necho hi\r\n' > "$W/userapp/scripts/nas-sync-state-lock.sh"         # CR on a later line only
        "$DASH" -c "$cmd" > "$W/out2" 2>&1; RC2=$?
        check "§$sec guard: a CR on a later line fails the build too (rc=$RC2)" '[ "$RC2" -ne 0 ] && grep -q "ERROR: CRLF" "$W/out2"'
    done
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

    # ---- edge cases of the lock library (§4.7, final wave) ----
    LOCKD="$STATE_DIR/locks/chunks.lock"
    rm -rf "$LOCKD"
    mklock() {  # mklock <dir age s> <heartbeat age s | none>: a lock held by "live-holder"
        rm -rf "$LOCKD"; mkdir -p "$LOCKD"
        printf 'run_id=live-holder\n' > "$LOCKD/owner"
        [ "$2" = none ] || "$REAL_TOUCH" -d "@$(( $(date +%s) - $2 ))" "$LOCKD/heartbeat"
        "$REAL_TOUCH" -d "@$(( $(date +%s) - $1 ))" "$LOCKD"          # last: creating the files above moves the dir's mtime
    }
    # m1: the heartbeat file EXISTS but stat on it fails (stale handle, I/O error). The lock dir's own mtime is the
    # acquisition time, 2 h old here: falling back to it would break a live lock. Only a MISSING heartbeat file
    # (the holder died between mkdir and its first touch) may fall back to the dir mtime.
    mkdir -p "$T/nostat"
    printf '#!/bin/bash\nfor a in "$@"; do case "$a" in */heartbeat) echo "stat: cannot statx: Stale file handle" >&2; exit 1;; esac; done\nexec %s "$@"\n' \
        "$(command -v stat)" > "$T/nostat/stat"
    chmod +x "$T/nostat/stat"
    mklock 7200 5
    PATH="$T/nostat:$PATH" timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/hbstat.log" 2>&1; RC=$?
    check "live lock is not broken when its heartbeat exists but cannot be stat'ed (exit 75) [rc=$RC]" \
        '[ "$RC" -eq 75 ] && grep -qx "run_id=live-holder" "$LOCKD/owner" 2>/dev/null && grep -q "cannot determine the age" "$T/hbstat.log"'
    mklock 7200 none
    timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/nohb.log" 2>&1; RC=$?
    check "lock with NO heartbeat file and an old dir mtime (holder died before its first touch) is broken [rc=$RC]" \
        '[ "$RC" -eq 0 ] && grep -q "stale" "$T/nohb.log"'
    # m2: LOCK_STALE below 2 x LOCK_HEARTBEAT would let a contender break a live lock: WARN and use 600/60.
    mklock 3 3
    LOCK_HEARTBEAT=5 LOCK_STALE=2 timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/inconsistent.log" 2>&1; RC=$?
    check "LOCK_STALE < 2 x LOCK_HEARTBEAT: WARN, defaults used, a 3 s-old live lock is not broken (exit 75) [rc=$RC]" \
        '[ "$RC" -eq 75 ] && grep -q "must be at least 2 x LOCK_HEARTBEAT" "$T/inconsistent.log" && grep -qx "run_id=live-holder" "$LOCKD/owner" 2>/dev/null'
    # M1: a value with a leading zero is a decimal number to `[` but OCTAL inside $(( )): `08` made bash abort the
    # whole check ("value too great for base", no WARN, no reset), and `0120` read as 80 and was reset to 600/60
    # although 120/60 is valid. LOCK_STALE=08 (HEARTBEAT 60) is inconsistent: WARN and defaults, the 3 s-old lock holds.
    mklock 3 3
    LOCK_STALE=08 timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/octal8.log" 2>&1; RC=$?
    check "LOCK_STALE=08 (leading zero): read as decimal 8 < 2 x 60: WARN says LOCK_STALE=8, defaults used, no arithmetic error, a 3 s-old lock holds (exit 75) [rc=$RC]" \
        '[ "$RC" -eq 75 ] && grep -q "LOCK_STALE=8 must be at least 2 x LOCK_HEARTBEAT" "$T/octal8.log" && ! grep -qiE "too great|syntax error|arithmetic" "$T/octal8.log" && grep -qx "run_id=live-holder" "$LOCKD/owner" 2>/dev/null'
    # LOCK_STALE=0120 (HEARTBEAT 60) is valid: no WARN, and 120 is the threshold in force: a 130 s-old lock is broken.
    mklock 130 130
    LOCK_STALE=0120 timeout --kill-after=10 300 "$S/generate-chunks.sh" > "$T/octal120.log" 2>&1; RC=$?
    check "LOCK_STALE=0120 (leading zero): read as decimal 120, no WARN, a 130 s-old lock is broken as stale > 120s (logged as 120s, not 0120s) [rc=$RC]" \
        '[ "$RC" -eq 0 ] && ! grep -q "must be at least" "$T/octal120.log" && grep -Eq "heartbeat 13[0-9]s ago > 120s" "$T/octal120.log"'
    rm -rf "$LOCKD"
    # M5: lock_release left the heartbeat's sleep running, and it held the job's stdout for up to LOCK_HEARTBEAT
    # seconds: `generate-... | tee` stalled after the job had finished. With LOCK_HEARTBEAT=10 the pipeline must
    # close within seconds of the generator's exit.
    t0=$(date +%s.%N)
    LOCK_HEARTBEAT=10 timeout --kill-after=10 300 "$S/generate-chunks.sh" 2>&1 | cat > "$T/pipe.log"
    t1=$(date +%s.%N)
    HELD=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b - a}')
    check "the heartbeat does not hold the job's stdout open after release (pipeline closed after ${HELD}s, LOCK_HEARTBEAT=10)" \
        'grep -q "^.* - Done\.$" "$T/pipe.log" && awk -v h="$HELD" "BEGIN{exit !(h < 5)}"'
    # m3: a SIGKILLed holder's heartbeat loop must die with it, or the orphan keeps a dead run's lock fresh for ever.
    # The generator runs in its own session (setsid), is killed 1 s after it took the lock, and the heartbeat must be
    # frozen by the time we look (2.5 s later, LOCK_HEARTBEAT=1), and stay frozen.
    rm -rf "$LOCKD"
    LOCK_HEARTBEAT=1 PATH="$T/slowfind:$PATH" setsid "$S/generate-chunks.sh" > "$T/orphan.log" 2>&1 &
    disown $!                                                      # its SIGKILL below is expected: no job notice
    for _ in $(seq 1 100); do grep -q '^pid=' "$LOCKD/owner" 2>/dev/null && break; sleep 0.05; done
    GPID=$(sed -n 's/^pid=//p' "$LOCKD/owner" 2>/dev/null)
    GPG=$(ps -o pgid= -p "${GPID:-0}" 2>/dev/null | tr -d ' ')
    sleep 1
    [ -n "$GPID" ] && kill -KILL "$GPID" 2>/dev/null
    sleep 2.5
    HB1=$(stat -c %.3Y "$LOCKD/heartbeat" 2>/dev/null || echo 0); sleep 2.2; HB2=$(stat -c %.3Y "$LOCKD/heartbeat" 2>/dev/null || echo 0)
    # remove what is left of the killed run (never our own process group)
    [ -n "$GPG" ] && [ "$GPG" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] && kill -KILL -- "-$GPG" 2>/dev/null
    rm -rf "$LOCKD" "$STATE_DIR/common"/.chunks.tmp*
    check "a SIGKILLed holder's heartbeat loop stops (heartbeat $HB1 -> $HB2)" '[ "$HB1" != 0 ] && [ "$HB1" = "$HB2" ]'
    # M1: three runs race for one stale lock. A slow contender renames away a FRESH lock (another run broke the stale one
    # and took the name), and a third run takes the name before the restore: the displaced lock cannot go back and
    # used to be stranded as locks/<job>.lock.stale.<run> for ever. The two overtaking runs are injected as a `mv` hook.
    M1S="$T/m1state"; rm -rf "$M1S"; mkdir -p "$M1S/locks/job.lock"
    printf 'run_id=dead-pod\n' > "$M1S/locks/job.lock/owner"
    "$REAL_TOUCH" -d "@$(( $(date +%s) - 1200 ))" "$M1S/locks/job.lock/owner" "$M1S/locks/job.lock"
    bash -c '
        . "$1"; STATE_DIR="$2"; log() { echo "$1"; }
        mv() {
            case "$1" in
                -T) mkdir "$LOCK_PATH" && printf "run_id=Z\n" > "$LOCK_PATH/owner" ;;
                *)  rm -rf "$LOCK_PATH"; mkdir "$LOCK_PATH"; printf "run_id=X\n" > "$LOCK_PATH/owner"; touch "$LOCK_PATH/heartbeat" ;;
            esac
            command mv "$@"
        }
        lock_acquire job' _ "$S/nas-sync-state-lock.sh" "$M1S" > "$T/m1race.log" 2>&1; RC=$?
    STRANDED=$(ls -A "$M1S/locks" | grep -c '\.lock\.stale\.')
    check "a lock displaced by mistake is not stranded as *.lock.stale.* when a third run takes the name (exit 75, stranded=$STRANDED) [rc=$RC]" \
        '[ "$RC" -eq 75 ] && [ "$STRANDED" -eq 0 ] && grep -q "could not restore.*displaced copy was removed" "$T/m1race.log"'
    # N2: the restore fails and NOTHING holds the name (the hook's `mv -T` fails): the displaced lock is kept as
    # job.lock.stale.<run>. It must not stay for ever. The next run that takes the lock removes it once its heartbeat is
    # older than LOCK_STALE (a displaced lock gets no more heartbeats), and never earlier, never the live lock, never a
    # dir of another name.
    N2S="$T/n2state"; rm -rf "$N2S"; mkdir -p "$N2S/locks/job.lock"
    printf 'run_id=dead-pod\n' > "$N2S/locks/job.lock/owner"
    "$REAL_TOUCH" -d "@$(( $(date +%s) - 1200 ))" "$N2S/locks/job.lock/owner" "$N2S/locks/job.lock"
    bash -c '
        . "$1"; STATE_DIR="$2"; log() { echo "$1"; }
        mv() {
            case "$1" in
                -T) return 1 ;;
                *)  rm -rf "$LOCK_PATH"; mkdir "$LOCK_PATH"; printf "run_id=X\n" > "$LOCK_PATH/owner"; touch "$LOCK_PATH/heartbeat" ;;
            esac
            command mv "$@"
        }
        lock_acquire job' _ "$S/nas-sync-state-lock.sh" "$N2S" > "$T/n2kept.log" 2>&1; RC=$?
    KEPT=$(ls -d "$N2S"/locks/job.lock.stale.* 2>/dev/null | head -n 1)
    check "restore failed, nothing holds the name: exit 75, the displaced lock is kept as job.lock.stale.* [rc=$RC]" \
        '[ "$RC" -eq 75 ] && [ -d "$KEPT" ] && grep -q "nothing holds the name.*kept as" "$T/n2kept.log"'
    n2run() {  # n2run <logfile>: a normal run that takes the lock; LOCK-INTACT = the live lock dir is still ours afterwards
        LOCK_HEARTBEAT=1 bash -c '. "$1"; STATE_DIR="$2"; log() { echo "$1"; }
            lock_acquire job; [ -d "$LOCK_PATH" ] && grep -qx "run_id=$LOCK_RUN_ID" "$LOCK_PATH/owner" && echo LOCK-INTACT' \
            _ "$S/nas-sync-state-lock.sh" "$N2S" > "$1" 2>&1
    }
    mkdir -p "$N2S/locks/jobx.lock.stale.zzz" "$N2S/locks/other.lock.stale.zzz"      # other names: never this job's business
    "$REAL_TOUCH" -d "@$(( $(date +%s) - 1200 ))" "$N2S"/locks/jobx.lock.stale.zzz "$N2S"/locks/other.lock.stale.zzz
    n2run "$T/n2run1.log"; RC=$?
    check "a displaced lock younger than LOCK_STALE is left alone by the next run, which takes the lock normally [rc=$RC]" \
        '[ "$RC" -eq 0 ] && [ -d "$KEPT" ] && grep -q LOCK-INTACT "$T/n2run1.log" && ! grep -q "Removed the leftover" "$T/n2run1.log"'
    "$REAL_TOUCH" -d "@$(( $(date +%s) - 1200 ))" "$KEPT/heartbeat" "$KEPT"           # 20 minutes without a heartbeat
    n2run "$T/n2run2.log"; RC=$?
    check "the next run that takes the lock removes the displaced lock once it is older than LOCK_STALE, and keeps its own lock [rc=$RC]" \
        '[ "$RC" -eq 0 ] && [ ! -d "$KEPT" ] && grep -q "Removed the leftover displaced lock" "$T/n2run2.log" && grep -q LOCK-INTACT "$T/n2run2.log"'
    check "the sweep is scoped to the lock name: jobx.lock.stale.* and other.lock.stale.* are untouched" \
        '[ -d "$N2S/locks/jobx.lock.stale.zzz" ] && [ -d "$N2S/locks/other.lock.stale.zzz" ]'

    # N3: a registry lookback with a leading zero. $(( )) reads 08 as an arithmetic error that abandons the whole registry
    # loop (no client at all, rc 1: even the valid ones lose their manifest) and 010 as octal 8. window = generated_at -
    # window_threshold_epoch in manifest.meta, in hours, must be the decimal value. A bad value (1x) is skipped with a WARN.
    win() { awk -F= '/^generated_at=/{g=$2} /^window_threshold_epoch=/{w=$2} END{if (g != "" && w != "") print (g - w) / 3600}' "$1" 2>/dev/null; }
    RG="$T/regstate"; rm -rf "$RG"
    printf '# comment\ncl08 08\ncl24 24\nclbad 1x\n' > "$T/clients-oct1.txt"
    LOCK_HEARTBEAT=1 STATE_DIR="$RG" REGISTRY_FILE="$T/clients-oct1.txt" timeout --kill-after=10 300 "$S/generate-manifests.sh" > "$T/oct1.log" 2>&1; RC=$?
    W08=$(win "$RG/clients/cl08/manifest.meta"); W24=$(win "$RG/clients/cl24/manifest.meta")
    check "registry lookback 08 (leading zero) is 8 hours and does not abandon the registry: cl24 is still served (rc=$RC, window cl08=${W08:-none}h cl24=${W24:-none}h)" \
        '[ "$RC" -eq 0 ] && [ "$W08" = 8 ] && [ "$W24" = 24 ] && grep -q "client=cl08 lookback=8h" "$T/oct1.log" && ! grep -qiE "too great|arithmetic" "$T/oct1.log"'
    check "registry lookback 1x is skipped with a WARN, the other clients are served" \
        'grep -q "WARN: bad lookback for .clbad. (.1x.)" "$T/oct1.log" && [ ! -d "$RG/clients/clbad" ] && [ -s "$RG/clients/cl24/manifest.meta" ]'
    rm -rf "$RG"
    printf 'cl010 010\ncl24 24\n' > "$T/clients-oct2.txt"
    LOCK_HEARTBEAT=1 STATE_DIR="$RG" REGISTRY_FILE="$T/clients-oct2.txt" timeout --kill-after=10 300 "$S/generate-manifests.sh" > "$T/oct2.log" 2>&1; RC=$?
    W010=$(win "$RG/clients/cl010/manifest.meta")
    check "registry lookback 010 means 10 hours, not octal 8 (rc=$RC, window=${W010:-none}h)" \
        '[ "$RC" -eq 0 ] && [ "$W010" = 10 ] && grep -q "client=cl010 lookback=10h" "$T/oct2.log"'
    rm -rf "$RG"
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

    # ---- the wrapper's sidecar-quit phase (§8.6) ----
    # A fake istio-proxy admin port: records POST /quitquitquit, holds its reply for <delay> s, answers, then exits
    # (so the wrapper sees the port close). A bare connect-and-close, like the wrapper's `nc -z` probe, is ignored.
    cat > "$T/sidecar.pl" <<'PEOF'
use IO::Socket::INET;
my ($port, $mark, $delay) = @ARGV;
my $l = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => $port, ReuseAddr => 1) or die "listen: $!";
while (my $c = $l->accept) {
    $c->autoflush(1);
    my $req = <$c>;
    if (defined $req && $req =~ m{^POST /quitquitquit}) {
        open(my $f, '>>', $mark) or die; print $f $req; close $f;
        sleep $delay;
        print $c "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        close $c; close $l; exit 0;
    }
    close $c;
}
PEOF
    # M4: nas-sync-lib.sh missing. v3.16 exited before the sidecar quit, so the Job pod hung NotReady instead of
    # failing. The wrapper and the dispatcher are copied next to NO library: the sync cannot run, but the sidecar
    # must still be quit and the exit status must be non-zero.
    mkdir -p "$T/nolib"
    cp "$S/dispatch-sync.sh" "$T/nolib/"
    sed "s#/userapp/scripts/dispatch-sync.sh#$T/nolib/dispatch-sync.sh#" "$S/run-with-sidecar-quit.sh" > "$T/nolib/run-with-sidecar-quit.sh"
    chmod +x "$T/nolib/"*.sh
    rm -f "$T/quit.mark"; AP=$(free_port 18900 18990)
    perl "$T/sidecar.pl" "$AP" "$T/quit.mark" 0 & SPID=$!; bg_add "$SPID"
    for _ in $(seq 1 50); do nc -z 127.0.0.1 "$AP" 2>/dev/null && break; sleep 0.1; done
    ISTIO_ADMIN_PORT="$AP" timeout --kill-after=5 60 "$T/nolib/run-with-sidecar-quit.sh" > "$T/nolib.log" 2>&1; RC=$?
    bg_stop "$SPID"
    check "wrapper without nas-sync-lib.sh still quits the sidecar and exits non-zero (rc=$RC)" \
        '[ "$RC" -ne 0 ] && [ -s "$T/quit.mark" ] && grep -q "nas-sync-lib.sh not found" "$T/nolib.log"'
    # M5: a TERM during the sidecar-quit phase must not re-enter the sync trap, whose group `kill -TERM 0` would also
    # hit curl/nc. The fake sidecar holds its reply for 4 s and the TERM goes to tini once the POST has arrived (the
    # quit phase). Armed, the trap ran once curl returned and logged "SIGTERM — signalling the sync"; replaced by
    # `exit "$SYNC_EXIT"`, the wrapper just ends. M2: and it ends with the status of the sync it already finished
    # (0 here): a bare `trap - TERM INT` left the default action, so a successful sync was reported as 143 and the
    # Job pod as Failed. (Under tini in a PID namespace like the other cases: that group TERM stays inside it.)
    fresh_src; echo tiny > "$T/src/tiny.txt"
    DST=$(fresh_dst quitphase)
    rm -f "$T/quit.mark"; AP=$(free_port 18900 18990)
    perl "$T/sidecar.pl" "$AP" "$T/quit.mark" 4 & SPID=$!; bg_add "$SPID"
    for _ in $(seq 1 50); do nc -z 127.0.0.1 "$AP" 2>/dev/null && break; sleep 0.1; done
    SYNC_MODE=standard LOCAL_NAS_PATH="$DST" ISTIO_ADMIN_PORT="$AP" \
        unshare --pid --fork --mount-proc tini -g -- "$S/run-with-sidecar-quit.sh" > "$T/quitphase.log" 2>&1 &
    u=$!
    for _ in $(seq 1 150); do [ -s "$T/quit.mark" ] && break; sleep 0.1; done
    tpid=$(pgrep -P "$u" -x tini | head -n 1)
    [ -n "$tpid" ] && kill -TERM "$tpid"
    for _ in $(seq 1 100); do kill -0 "$u" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$u" 2>/dev/null && { kill -KILL "$tpid" "$u" 2>/dev/null; echo "(killed after 10s)" >> "$T/quitphase.log"; }
    wait "$u" 2>/dev/null; QRC=$?
    bg_stop "$SPID"
    check "TERM during the sidecar-quit phase does not re-enter the sync trap and keeps the sync's exit status 0 (rc=$QRC)" \
        '[ -s "$T/quit.mark" ] && [ -n "$tpid" ] && grep -q "Sync exited: 0" "$T/quitphase.log" && ! grep -q "SIGTERM — signalling" "$T/quitphase.log" && [ "$QRC" -eq 0 ]'
    # log() is printf %()T in the wrapper and the dispatcher since the final wave: same format as before.
    check "log() lines keep their format: '<date> <time> [wrapper] …' and '… [dispatch] …'" \
        'grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[wrapper\] === Wrapper start" "$T/quitphase.log" && grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[dispatch\] Mode: standard" "$T/quitphase.log"'
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
        # (c) SIGTERM right at the start, before the initial sync has been forked. A TERM that lands
        # after the trap is installed and before the fork finds nothing to signal; an entrypoint that
        # then starts the (unbounded) sync anyway never stops it, and the pod's SIGKILL leaves a temp
        # file behind. That window is ~2 ms wide: the trap goes in ~25-35 ms after the container starts
        # (measured on a fast machine) and the sync is forked 1-2 ms later, so a bare "TERM at ~50 ms"
        # usually arrives after the fork and never reaches it. The date shim above therefore holds the
        # entrypoint inside the window; the TERM goes out as soon as the shim's marker file shows it is
        # holding (polled, up to 5 s, so a slow machine only takes longer). If the marker never shows,
        # the TERM is sent anyway and the run fails loudly with held=no.
        # The slow rsync shim makes a sync that does start outlast the 15 s limit. A run counts as
        # clean only if the container stopped within 15 s, exited 143 and left no temp file, AND it
        # really reached the window: the shim held the ENTRYPOINT's date call (the marker names its
        # command line) and the trap handled the TERM (otherwise the run proves nothing: a changed
        # log line, or a log() that no longer forks date).
        fresh_src; mkdir -p "$T/src/big"; head -c 40000000 /dev/urandom > "$T/src/big/blob.bin"
        shim_set 1000                                                         # ~1 MB/s: an unsignalled sync runs ~40 s
        EARLY_N=10; EARLY_OK=0; EARLY_BAD=""
        for i in $(seq 1 "$EARLY_N"); do
            DST=$(fresh_dst "dep-early-$i"); elog="$T/dep-early-$i.log"
            NGB_HELD="$T/dep-early-$i.held" PATH="$T/shim-date:$PATH" SYNC_MODE=standard LOCAL_NAS_PATH="$DST" CRON_SCHEDULE='* * * * *' \
                unshare --pid --fork --mount-proc tini -g -- "$S/entrypoint-deployment.sh" > "$elog" 2>&1 &
            u=$!
            for _ in $(seq 1 100); do [ -s "$T/dep-early-$i.held" ] && break; sleep 0.05; done
            tpid=$(pgrep -P "$u" -x tini | head -n 1)
            if [ -z "$tpid" ]; then
                EARLY_BAD="$EARLY_BAD $i(no tini)"; kill -KILL "$u" 2>/dev/null; wait "$u" 2>/dev/null; continue
            fi
            t0=$(date +%s); kill -TERM "$tpid"
            for _ in $(seq 1 200); do kill -0 "$u" 2>/dev/null || break; sleep 0.1; done
            took=$(( $(date +%s) - t0 ))
            kill -0 "$u" 2>/dev/null && kill -KILL "$tpid" "$u" 2>/dev/null
            wait "$u" 2>/dev/null; erc=$?
            orph=$(find "$DST" -name '.blob*' -type f ! -path '*/.rsync-partial/*' | wc -l)
            held=no;   grep -q entrypoint-deployment "$T/dep-early-$i.held" 2>/dev/null && held=yes   # the shim parked the entrypoint
            ontrap=no; grep -qF 'stopping cron, signalling' "$elog" && ontrap=yes      # and the trap handled the TERM
            if [ "$took" -le 15 ] && [ "$erc" -eq 143 ] && [ "$orph" -eq 0 ] && [ "$held" = yes ] && [ "$ontrap" = yes ]; then
                EARLY_OK=$((EARLY_OK+1))
            else
                EARLY_BAD="$EARLY_BAD $i(took=${took}s rc=$erc orphans=$orph held=$held ontrap=$ontrap)"
            fi
        done
        check "Deployment, SIGTERM right at start: $EARLY_OK/$EARLY_N runs stopped cleanly within 15 s${EARLY_BAD:+ — failed:$EARLY_BAD}" \
            '[ "$EARLY_OK" -eq "$EARLY_N" ]'
        # (d) a cron-launched run whose rsync cleanup is SLOW. On a TERM, rsync keeps the partial by
        # closing the temp file, creating .rsync-partial/ and renaming the temp file into it. A SECOND
        # TERM that lands during those steps makes rsync run its exit handler again, which skips the
        # rename: the temp file is orphaned or lost. A drain that re-TERMs every run once a second does
        # exactly that whenever the cleanup outlasts its first re-TERM (a large close() flushing to a
        # busy NAS). On tmpfs the cleanup takes ~1 ms, so the stall is injected: an LD_PRELOAD, built
        # here with cc from a few lines of C, makes rename() into .rsync-partial/ wait STALL_MS with
        # every signal blocked, like a killable NFS wait (a TERM sent meanwhile fires the moment it
        # ends). The rsync shim preloads it for the client rsync only (shim_set's 3rd and 4th args).
        # Two choices make the check deterministic:
        #  - STALL_MS=3000. rsync starts the cleanup ~0.4 s after the TERM (its handlers sleep 400 ms),
        #    so the stall covers the drain's re-TERMs at about +1 s, +2 s and +3 s. 1.5 s already
        #    failed every time against the 7aaf015 guide (6/6); the rest is margin for a slow machine.
        #  - the preload also delays the generator's kill(SIGUSR1) by 300 ms. That is how the generator
        #    tells the receiver to wrap up, and it lands at the same ~0.4 s instant as the end of the
        #    receiver's own TERM handler. If USR1 wins, the receiver cleans up INSIDE that handler,
        #    where TERM stays masked and no second TERM can reach it: without the delay the check
        #    passed about half the time against 7aaf015 (5 of 10 at 3 s), whatever the stall.
        #    Delayed, the receiver always cleans up from its main flow, where a repeated TERM hurts.
        STALL_MS=3000
        STALL_SO=""
        if command -v cc >/dev/null 2>&1; then
            cat > "$T/stall.c" <<'CEOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
/* rename() into .rsync-partial/ waits NGB_STALL_MS with every signal blocked, and leaves the
   NGB_MARK file behind as proof that it did. */
int rename(const char *from, const char *to) {
    static int (*real)(const char *, const char *);
    const char *ms = getenv("NGB_STALL_MS");
    if (!real) real = (int (*)(const char *, const char *))dlsym(RTLD_NEXT, "rename");
    if (ms && to && strstr(to, ".rsync-partial/")) {
        long n = atol(ms);
        struct timespec req = { n / 1000, (n % 1000) * 1000000L }, rem;
        sigset_t all, old;
        int f = open(NGB_MARK, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (f >= 0) close(f);
        sigfillset(&all);
        sigprocmask(SIG_BLOCK, &all, &old);
        while (nanosleep(&req, &rem) == -1 && errno == EINTR) req = rem;
        sigprocmask(SIG_SETMASK, &old, NULL);
    }
    return real(from, to);
}
/* kill(pid, SIGUSR1), which the generator sends to the receiver, goes out 300 ms late. */
int kill(pid_t pid, int sig) {
    static int (*real)(pid_t, int);
    struct timespec req = { 0, 300000000L }, rem;
    if (!real) real = (int (*)(pid_t, int))dlsym(RTLD_NEXT, "kill");
    if (sig == SIGUSR1 && getenv("NGB_STALL_MS"))
        while (nanosleep(&req, &rem) == -1 && errno == EINTR) req = rem;
    return real(pid, sig);
}
CEOF
            cc -shared -fPIC -O1 -DNGB_MARK="\"$T/stall.mark\"" -o "$T/stall.so" "$T/stall.c" -ldl 2>"$T/stall.cc.log" \
                && STALL_SO="$T/stall.so"
        fi
        if ! command -v cc >/dev/null 2>&1; then
            skip "Deployment, cron-launched run, slow cleanup: no C compiler (cc) to build the LD_PRELOAD stall (install gcc and libc6-dev)"
        elif [ -z "$STALL_SO" ]; then
            skip "Deployment, cron-launched run, slow cleanup: cc could not build the LD_PRELOAD stall: $(head -n 1 "$T/stall.cc.log") (missing libc6-dev?)"
        else
            fresh_src; echo tiny > "$T/src/tiny.txt"
            DST=$(fresh_dst dep-slow)
            ( for _ in $(seq 1 300); do grep -q 'Initial sync done' "$T/dep-slow.log" 2>/dev/null && break; sleep 0.2; done
              mkdir -p "$T/src/big"; head -c 40000000 /dev/urandom > "$T/src/big/blob.bin" ) &
            shim_set 4000 "" "$STALL_SO" "$STALL_MS"
            SYNC_MODE=standard LOCAL_NAS_PATH="$DST" CRON_SCHEDULE='* * * * *' \
                sigterm_run "Deployment, cron-launched run, slow cleanup" "$DST" "$T/dep-slow.log" "-g" -- "$S/entrypoint-deployment.sh"
            # Without this the four checks above pass vacuously whenever the preload does not load
            # (ld.so only warns, e.g. on a noexec /tmp) or never fires: the run is then a plain single-TERM run.
            check "Deployment, cron-launched run, slow cleanup: the preload really stalled rename() (marker)" '[ -e "$T/stall.mark" ]'
        fi
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
