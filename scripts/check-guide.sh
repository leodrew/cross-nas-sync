#!/bin/bash
#############################################
# check-guide.sh — consistency harness for the
# cross-cluster rsync guide.
#
# This repo ships documentation whose fenced code blocks ARE the deliverable: they
# get copied verbatim into real files at deploy time. Nothing here is built or run,
# so "tests" mean proving the blocks are valid and the document is internally
# consistent. Run this before every commit that touches a guide.
# Runtime behavior (rsync, signals, locks) is covered by scripts/test-guide-behavior.sh.
#
# Usage:  scripts/check-guide.sh [guide.md ...]
#         (defaults to the newest cross-cluster-rsync-guide-v*.md)
#############################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FAIL=0
WARN=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [ "$#" -gt 0 ]; then
    GUIDES=("$@")
else
    mapfile -t GUIDES < <(ls -1 cross-cluster-rsync-guide-v*.md 2>/dev/null | sort -V | tail -1)
fi
[ "${#GUIDES[@]}" -gt 0 ] || { echo "No guide file found."; exit 1; }

# Pick a python that can import yaml; empty means skip YAML parsing.
PY=""
for c in python3 py python; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c "import yaml" >/dev/null 2>&1; then PY="$c"; break; fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Split a markdown file into its fenced blocks: one file per block, named
# NNN.<lang>, plus a sidecar NNN.line recording the fence's line number.
split_blocks() {  # $1=guide  $2=outdir
    awk -v out="$2" '
        /^```[a-zA-Z]*$/ {
            if (inb) { close(f); inb=0; next }
            lang = substr($0, 4)
            if (lang == "") lang = "none"
            n++
            f = sprintf("%s/%03d.%s", out, n, lang)
            printf "%d\n", NR > (f ".line")
            close(f ".line")
            inb = 1
            next
        }
        inb { print > f }
    ' "$1"
}

for GUIDE in "${GUIDES[@]}"; do
    printf '\n\033[1m=== %s ===\033[0m\n' "$GUIDE"
    [ -f "$GUIDE" ] || { fail "file not found"; continue; }

    BD="$WORK/$(basename "$GUIDE" .md)"
    mkdir -p "$BD"
    split_blocks "$GUIDE" "$BD"

    # ---------------------------------------------------------------
    head2 "1. Line endings (CRLF is the highest-consequence regression here)"
    # A \r in a script shebang makes tini fail with "No such file or directory".
    # Count CR BYTES with tr, not grep: MSYS/Git-Bash grep strips a CR pattern from argv,
    # leaving an empty pattern that matches every line — a silent false positive.
    CR=$(tr -cd '\r' < "$GUIDE" | wc -c | tr -d ' ')
    if [ "$CR" -eq 0 ]; then pass "no CR bytes"; else fail "$CR CR byte(s) present — run: tr -d '\r' < $GUIDE > tmp && mv tmp $GUIDE"; fi

    # ---------------------------------------------------------------
    head2 "2. Shell syntax (bash -n on every fenced bash block)"
    NB=0
    for f in "$BD"/*.bash "$BD"/*.sh; do
        [ -f "$f" ] || continue
        NB=$((NB+1))
        LN=$(cat "${f}.line" 2>/dev/null || echo '?')
        if err=$(bash -n "$f" 2>&1); then
            :
        else
            fail "block at line $LN: $(printf '%s' "$err" | head -3 | tr '\n' ' ')"
        fi
    done
    [ "$NB" -gt 0 ] && pass "$NB bash block(s) parsed" || warn "no bash blocks found"

    # ---------------------------------------------------------------
    head2 "3. YAML validity"
    NY=0; YBAD=0
    for f in "$BD"/*.yaml "$BD"/*.yml; do
        [ -f "$f" ] || continue
        NY=$((NY+1))
        LN=$(cat "${f}.line" 2>/dev/null || echo '?')
        # Placeholder scalars like ISTIO_EXTERNAL_IP_HERE are quoted in the guide, so
        # real parsing works. Tabs are never valid YAML indentation.
        if grep -qP '^\t' "$f" 2>/dev/null; then
            fail "block at line $LN: TAB used for YAML indentation"; YBAD=1
        fi
        if [ -n "$PY" ]; then
            if err=$("$PY" -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1],encoding="utf-8")))' "$f" 2>&1); then
                :
            else
                fail "block at line $LN: $(printf '%s' "$err" | tail -2 | tr '\n' ' ')"; YBAD=1
            fi
        fi
    done
    if [ -z "$PY" ]; then
        warn "no python with pyyaml found — YAML parsed structurally only (pip install pyyaml)"
    fi
    [ "$NY" -gt 0 ] && [ "$YBAD" -eq 0 ] && pass "$NY yaml block(s) parsed"
    [ "$NY" -eq 0 ] && warn "no yaml blocks found"

    # ---------------------------------------------------------------
    head2 "4. Forbidden: --delete (target-only files must never be removed)"
    if grep -n -- '--delete' "$GUIDE" | grep -qv 'never add\|Do NOT\|banned\|no --delete\|without --delete'; then
        grep -n -- '--delete' "$GUIDE" | grep -v 'never add\|Do NOT\|banned\|no --delete\|without --delete' | head -5
        fail "--delete appears outside a prohibition note"
    else
        pass "no --delete in any command"
    fi

    # ---------------------------------------------------------------
    head2 "5. Placeholders intact"
    for p in 'your-registry.example.com' 'ISTIO_EXTERNAL_IP_HERE'; do
        if grep -q "$p" "$GUIDE"; then pass "$p present"; else fail "$p missing — was a placeholder replaced with a real value?"; fi
    done
    if grep -qF '◄ MODIFY' "$GUIDE"; then pass "◄ MODIFY markers present"; else fail "◄ MODIFY markers missing"; fi

    # ---------------------------------------------------------------
    head2 "6. Section cross-references resolve"
    # Collect heading numbers: "## 4. …", "### 4.3 …", "### 9A.2 …", "### 10B.1 …"
    grep -oE '^#{2,4} [0-9]+[A-Z]?(\.[0-9]+)*\.? ' "$GUIDE" \
        | sed -E 's/^#+ //; s/ $//; s/\.$//' | sort -u > "$WORK/headings.txt"
    # Collect §refs used in prose
    grep -oE '§[0-9]+[A-Z]?(\.[0-9]+)*' "$GUIDE" | sed 's/§//' | sort -u > "$WORK/refs.txt"
    MISSING=""
    while read -r r; do
        [ -n "$r" ] || continue
        # A ref to §4 matches heading "4"; a ref to §9A.2 matches "9A.2".
        grep -qx "$r" "$WORK/headings.txt" && continue
        # Allow refs to a parent section that exists only as "## N."
        grep -qE "^${r}(\.|$)" "$WORK/headings.txt" && continue
        MISSING="$MISSING $r"
    done < "$WORK/refs.txt"
    if [ -n "$MISSING" ]; then fail "§refs with no matching heading:$MISSING"; else pass "all §refs resolve"; fi

    # ---------------------------------------------------------------
    head2 "7. File Checklist (§14) lists every defined artifact"
    # Every "### N.N File: `path`" must appear in the checklist by basename.
    grep -oE '^#{3} [0-9]+[A-Z]?(\.[0-9]+)* File: `[^`]+`' "$GUIDE" \
        | sed -E 's/.*`([^`]+)`.*/\1/' | xargs -n1 basename 2>/dev/null | sort -u > "$WORK/defined.txt"
    CHK=$(awk '/^## 14\./{f=1} f' "$GUIDE")
    MISSING=""
    while read -r b; do
        [ -n "$b" ] || continue
        printf '%s' "$CHK" | grep -qF "$b" || MISSING="$MISSING $b"
    done < "$WORK/defined.txt"
    if [ -n "$MISSING" ]; then fail "defined but not in §14 checklist:$MISSING"; else pass "$(wc -l < "$WORK/defined.txt" | tr -d ' ') defined file(s) all listed in §14"; fi

    # ---------------------------------------------------------------
    head2 "8. Fixed conventions"
    grep -q 'namespace: ea-pmc' "$GUIDE" && pass "namespace ea-pmc" || fail "namespace ea-pmc not found"
    grep -q '8787' "$GUIDE" && pass "port 8787" || fail "port 8787 not found"
    grep -q 'reverse lookup = no' "$GUIDE" && pass "reverse lookup = no (127.0.0.6 DNS fix)" || fail "reverse lookup = no missing"

    # ---------------------------------------------------------------
    head2 "9. v3.15 defect-fix regressions"
    # `--` so patterns starting with a dash are not parsed as grep options.
    check_has() { if grep -qF -e "$2" -- "$GUIDE"; then pass "$1"; else fail "$1 — expected to find: $2"; fi; }
    case "$GUIDE" in
      *v3.1[5-9]*|*v3.[2-9]*)
        check_has "A1 CLIENT_ID in Deployment cron env allow-list" "CLIENT_ID|VERIFY_"
        check_has "A6: --partial-dir set"                          "--partial-dir=.rsync-partial"
        check_has "B1: preflight retry"                            "wait_for_remote"
        # Must be the real pod annotation, not a passing mention in prose.
        if grep -qF -e 'proxy.istio.io/config' -- "$GUIDE" \
           && grep -qF -e 'holdApplicationUntilProxyStarts' -- "$GUIDE"; then
            pass "B1: Istio proxy-start annotation present"
        else
            fail "B1: proxy.istio.io/config holdApplicationUntilProxyStarts annotation missing"
        fi
        check_has "B2: rsync rc 23/24 tolerated"                   "rsync_rc_ok"
        check_has "B3: Deployment cron overlap guard"              "flock -n /var/lock/nas-sync.lock"
        check_has "B6: status file"                                ".nas-sync-status"
        check_has "verify mode"                                    "VERIFY RESULT"
        check_has "chunked reconcile"                              "chunks.meta"
        # B4: cron must be registered exactly once (no `crontab <file>` alongside /etc/cron.d)
        if grep -qE '^\s*crontab /etc/cron\.d' "$GUIDE"; then
            fail "B4: cron registered twice (crontab + /etc/cron.d)"
        else
            pass "B4: cron registered once (/etc/cron.d only)"
        fi
        # A5: snapshot dirs pruned by name at all depths
        if grep -qF -e "-name '.snapshot'" -- "$GUIDE"; then
            pass "A5: .snapshot pruned by name at all depths"
        else
            fail "A5: expected -name '.snapshot' -prune (path-based prune only matches the root)"
        fi
        ;;
      *) warn "pre-v3.15 guide — skipping v3.15 regression checks" ;;
    esac

    # ---------------------------------------------------------------
    head2 "10. v3.16 defect-fix regressions"
    # IDs are the findings in docs/superpowers/specs/2026-10-01-v316-review-fixes-design.md §2.
    check_absent() { if grep -qF -e "$2" -- "$GUIDE"; then fail "$1 — must not appear: $2"; else pass "$1"; fi; }
    # Text of one guide section: from its "### <sec> File" heading up to the next "### " heading.
    sec_text() { awk -v s="### $1 File" 'index($0, s) == 1 {f = 1; next} f && /^### / {exit} f' "$GUIDE"; }
    # No -q: with pipefail an early grep exit could SIGPIPE awk and fail a check that passed.
    check_in_sec() { if sec_text "$2" | grep -F -e "$3" -- >/dev/null; then pass "$1"; else fail "$1 — expected to find: $3"; fi; }
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
        # §8.7 also contains this line, so the wrapper check is scoped to §8.6.
        check_in_sec "F6: wrapper signals its process group"            8.6 "kill -TERM 0 2>/dev/null"
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
        # §8.7 shutdown fixes (code lines, not comments) that only the slow runtime suite covers otherwise.
        check_in_sec "F6: §8.7 a TERM at launch still signals the initial sync" 8.7 '[ -n "$GOT_TERM" ] && kill -TERM 0 2>/dev/null'
        check_in_sec "F6: §8.7 a TERM at launch still stops cron"        8.7 '[ -n "$GOT_TERM" ] && kill -TERM "$CRON_PID"'
        check_in_sec "F6: §8.7 drain signals each run group once (a repeat TERM loses the partial)" 8.7 'case "$SIGNALLED" in'
        # A launch guarded by a drain on the previous code line (comments and blanks skipped): a TERM before
        # the launch must not start an unbounded sync or cron. The post-wait drains do not count.
        PRELAUNCH=$(sec_text 8.7 | awk '/^[[:space:]]*(#|$)/ {next}
            /^[[:space:]]*(flock -n|cron -f)/ && prev ~ /^[[:space:]]*\[ -n "\$GOT_TERM" \] && drain_and_exit/ {n++}
            {prev = $0} END {print n + 0}')
        if [ "$PRELAUNCH" -ge 2 ]; then
            pass "F6: §8.7 no launch after a TERM (initial sync and cron guarded)"
        else
            fail "F6: §8.7 pre-launch drain_and_exit guards $PRELAUNCH of 2 launches (initial sync, cron) — a TERM before launch starts a sync nobody signals"
        fi
        check_has    "F7: status records interruptions"                 "interrupted=TERM"
        ;;
      *) warn "pre-v3.16 guide — skipping v3.16 regression checks" ;;
    esac
done

printf '\n'
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31m%d check(s) FAILED\033[0m, %d warning(s)\n' "$FAIL" "$WARN"
    exit 1
fi
printf '\033[32mAll checks passed\033[0m (%d warning(s))\n' "$WARN"
exit 0
