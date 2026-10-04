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
        # A shell pattern, not `printf | grep -q`: under pipefail that pipe fails now and then when grep exits early.
        case "$CHK" in *"$b"*) ;; *) MISSING="$MISSING $b" ;; esac
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
    #
    # Every pin is matched against CODE: the guide's fenced blocks, one section at a time (or all of
    # them), with indentation, comment lines, trailing comments and trailing blanks removed. Prose,
    # comments and the changelog quote these strings, so a pin they could satisfy would stay green
    # with the code gone. Only bash, sh, dockerfile and yaml blocks are code: a bare or ```text
    # block (sample output) is not.
    #   sec_text <sec>          one section's raw text, "### <sec> File" up to the next ## or ###
    #                           heading (empty <sec>: the whole guide); a fence line hides headings.
    #                           A trailing CR is dropped, so a CRLF guide fails section 1 once
    #                           instead of failing every pin here
    #   code_only [lang-regex]  filter: the fenced lines only (of those languages)
    #   sec_code <sec> [langs]  the two combined; guide_code [langs] = the whole guide's code blocks
    #   yaml_code [sec]         the same for ```yaml blocks only (the whole guide when <sec> is empty)
    # Every matcher reads its whole input: with pipefail an early grep -q exit could SIGPIPE the
    # producer and fail a check that passed. Several pin arguments = that many CONSECUTIVE code
    # lines, each containing its argument (the comments between them do not count). No pin, or an
    # empty one, is a bug in this script and never a pass: has_pin returns 2 and every caller FAILs.
    CODE_LANGS='^(bash|sh|dockerfile|ya?ml)$'
    sec_text() {
        awk -v s="${1:+### $1 File}" '
            BEGIN { f = (s == "") }
            { sub(/\r$/, ""); fl = ($0 ~ /^```[a-zA-Z]*$/) }
            !fence && !fl && f && s != "" && /^###? / { exit }
            !fence && !fl && !f && index($0, s) == 1 { f = 1; next }
            f { print }
            fl { fence = !fence }' "$GUIDE"
    }
    code_only() {
        awk -v L="${1:-$CODE_LANGS}" '
            /^```[a-zA-Z]*$/ { fence = !fence; if (fence) keep = (tolower(substr($0, 4)) ~ L); next }
            fence && keep {
                sub(/^[ \t]+/, "")
                if ($0 == "" || $0 ~ /^#/) next
                sub(/[ \t]+#.*$/, "")
                sub(/[ \t]+$/, "")
                print
            }'
    }
    sec_code()   { sec_text "$1" | code_only "${2:-}"; }
    guide_code() { sec_text "" | code_only "${1:-}"; }
    yaml_code()  { sec_code "${1:-}" '^ya?ml$'; }
    has_pin() {  # stdin: code lines; arguments: the pin's lines. rc 0 found, 1 not found, 2 no pin or an empty one
        local p
        if [ "$#" -eq 0 ]; then
            echo "check-guide.sh bug: has_pin called without a pin" >&2; cat > /dev/null; return 2
        fi
        for p in "$@"; do
            [ -n "$p" ] || { echo "check-guide.sh bug: has_pin called with an empty pin" >&2; cat > /dev/null; return 2; }
        done
        local IFS=$'\n'
        PIN="$*" awk '
            BEGIN { n = split(ENVIRON["PIN"], P, "\n") }
            {
                for (k = 1; k < n; k++) W[k] = W[k + 1]
                W[n] = $0
                if (++c >= n) { m = 1; for (k = 1; k <= n; k++) if (index(W[k], P[k]) == 0) m = 0; if (m) hit = 1 }
            }
            END { exit !hit }'
    }
    fn_body() { FN="$1" awk 'BEGIN { s = ENVIRON["FN"] "() {" } index($0, s) == 1 { f = 1; next } f && $0 == "}" { f = 0; next } f'; }
    pins() { local o="$1" p; shift; for p in "$@"; do o="$o ⏎ $p"; done; printf '%s' "$o"; }
    BADPIN="check-guide.sh bug: no pin, or an empty one"
    check_in_sec() {  # label sec pin...: the section's code has this line (these consecutive lines)
        local label="$1" sec="$2" rc; shift 2
        sec_code "$sec" | has_pin "$@"; rc=$?
        case "$rc" in
            0) pass "$label" ;;
            1) fail "$label — expected to find: $(pins "$@") (in §$sec code)" ;;
            *) fail "$label — $BADPIN" ;;
        esac
    }
    check_in_fn() {   # label sec function pin...: ... inside that shell function
        local label="$1" sec="$2" fn="$3" rc; shift 3
        sec_code "$sec" | fn_body "$fn" | has_pin "$@"; rc=$?
        case "$rc" in
            0) pass "$label" ;;
            1) fail "$label — expected to find: $(pins "$@") (in §$sec $fn)" ;;
            *) fail "$label — $BADPIN" ;;
        esac
    }
    check_absent() {  # label pin [sec]: in no code line (of the section, else of the guide)
        local src rc
        if [ -n "${3:-}" ]; then src=$(sec_code "$3"); else src=$(guide_code); fi
        printf '%s\n' "$src" | has_pin "${2-}"; rc=$?
        case "$rc" in
            0) fail "$1 — must not appear: $2" ;;
            1) pass "$1" ;;
            *) fail "$1 — $BADPIN" ;;
        esac
    }
    check_order() {   # label sec first second: the first code line holding $first precedes the first holding $second
        if sec_code "$2" | A="$3" B="$4" awk '
            !a && index($0, ENVIRON["A"]) { a = NR }
            !b && index($0, ENVIRON["B"]) { b = NR }
            END { exit !(a && b && a < b) }'; then pass "$1"; else fail "$1 — expected in §$2 code: $3 ... before ... $4"; fi
    }
    count_code() {    # sec pin: code lines of the section that START with the pin
        sec_code "$1" | P="$2" awk 'index($0, ENVIRON["P"]) == 1 { n++ } END { print n + 0 }'
    }
    check_each_pod_spec() {  # pass-label fail-what yaml-line: that exact YAML line, in the YAML of each client pod spec's own section
        local s n=0 missing=""
        for s in 9A.2 9A.4 9A.5 10B.1; do
            if [ "$(yaml_code "$s" | L="$3" awk '$0 == ENVIRON["L"] { n++ } END { print n + 0 }')" -ge 1 ]; then
                n=$((n+1))
            else
                missing="$missing §$s"
            fi
        done
        if [ "$n" -eq 4 ]; then pass "$1 on all $n client pod specs"; else fail "$2 missing from the YAML of:$missing (§9A.2, §9A.4, §9A.5, §10B.1 each need it)"; fi
    }
    case "$GUIDE" in
      *v3.1[6-9]*|*v3.[2-9]*)
        # ---- fences: every pin below reads the guide through them, so a stray or missing fence line
        # (which would otherwise surface as dozens of unrelated "expected to find" FAILs) is reported first.
        # A tagged opener (```bash) can never close a block: seeing one inside a block means the block
        # before it was never closed, and that block's opening line is the one to look at.
        FENCE_REPORT=$(awk '
            { sub(/\r$/, "") }
            /^```[a-zA-Z]*$/ {
                n++
                if (open && length($0) > 3 && !bad) { bad = open; nxt = NR }
                open = open ? 0 : NR
            }
            END {
                if (bad)       print "bad the block opened at line " bad " is never closed (the tagged fence at line " nxt " starts inside it)"
                else if (open) print "bad " n " fence lines (odd), the block opened at line " open " is never closed"
                else           print "ok " n " fence lines"
            }' "$GUIDE")
        case "$FENCE_REPORT" in
            "ok "*)  pass "fenced blocks pair up (${FENCE_REPORT#ok })" ;;
            "bad "*) fail "fenced blocks do not pair up: ${FENCE_REPORT#bad }" ;;
            *)       fail "fenced blocks: the fence scan produced no result" ;;
        esac
        # ---- F1: chunk generations
        check_in_sec "F1: chunk files carry their generation"           4.6 '- "${TMP_DIR}/chunk-${GEN}-"'
        check_in_sec "F1: chunks.meta records the generation"           4.6 'generation=%s'
        check_in_sec "F1: client retries an inconsistent chunk set"     8.3 'sleep "$CHUNK_RETRY_WAIT"'
        check_in_sec "F1: client counts only the chunk files of the generation in chunks.meta" 8.3 'CHUNK_GLOB="chunk-${CHUNK_GEN}-*.txt"'
        check_in_sec "F1: client syncs only the chunk files of that generation" 8.3 'find "$CHUNK_DIR" -maxdepth 1 -name "$CHUNK_GLOB" -print0'
        # ---- F2: generator lock
        check_in_sec "F2: manifest generator takes the state-dir lock"  4.3 'lock_acquire manifests'
        check_in_sec "F2: chunk generator takes the state-dir lock"     4.6 'lock_acquire chunks'
        check_in_sec "F2: lock library is COPYed into the server image" 4.4 'COPY nas-sync-state-lock.sh'
        check_in_sec "F2: a held lock exits 75, the second run does nothing"  4.7 'held by [' 'exit "$LOCK_EXIT_HELD"'
        check_in_sec "F2: an unreadable lock age exits 75 (fails closed)" 4.7 'cannot determine the age of lock' 'exit "$LOCK_EXIT_HELD"'
        check_in_sec "F2: the held/unknown exit code is 75"             4.7 'LOCK_EXIT_HELD=75'
        check_in_sec "F2: LOCK_HEARTBEAT read as decimal (08 is an octal error: no lock)" 4.7 'LOCK_HEARTBEAT=$((10#$LOCK_HEARTBEAT))'
        check_in_sec "F2: LOCK_STALE read as decimal (08 is an octal error: no lock)"     4.7 'LOCK_STALE=$((10#$LOCK_STALE))'
        check_in_sec "F2: _lock_sweep defined (displaced lock dirs pile up)"  4.7 '_lock_sweep() {'
        check_in_sec "F2: lock_acquire calls _lock_sweep"               4.7 '_lock_sweep "$name"'
        # ---- F3/F4: folder names
        check_in_sec "F3/F4: parallel passes folder names via --files-from" 8.3  '-r --from0 --files-from=-'
        check_in_sec "F3/F4: verify passes folder names via --files-from"   8.10 '-r --from0 --files-from=-'
        check_in_sec "F3/F4: the shared top-level lister is defined"        8.11 'list_top_dirs() {'
        check_in_sec "F3/F4: parallel lists top-level dirs with it"         8.3  'list_top_dirs > '
        check_in_sec "F3/F4: verify lists top-level dirs with it"           8.10 'list_top_dirs > '
        check_in_sec "F3/F4: library is COPYed into the client image"       8.8  'COPY nas-sync-lib.sh'
        check_in_sec "F4: the lister's perl is checked at build time"       8.8  '&& command -v perl'
        check_absent "F4: v3.15 \$NF folder parser is gone"                 '$NF != "."'
        # The listing must not miss a folder: rc 0 and 24 only. rc 23 (an entry that exists was unreadable) would drop it.
        check_in_sec "F3/F4: parallel's top-level listing accepts rc 0/24 only" 8.3  'case "$LIST_RC" in' '0|24) ;;' 'die "Cannot list top-level folders'
        check_in_sec "F3/F4: verify's top-level listing accepts rc 0/24 only"   8.10 'case "$LIST_RC" in' '0|24) ;;' 'die "Tier 2: cannot list top-level dirs'
        # ---- F5: non-recursive top-level pass
        check_in_sec "F5: top-level pass is non-recursive"              8.3 'rsync $RSYNC_FLAGS --no-recursive --dirs'
        # Every rsync command line with --dirs must be non-recursive: -a implies -r. Code only, \ continuations joined.
        BADDIRS=$(guide_code | awk '
            function chk(s) { if (s ~ /rsync .*--dirs/ && s !~ /--no-recursive --dirs/) n++ }
            { cur = cur $0 }
            cur ~ /\\$/ { sub(/\\$/, " ", cur); next }
            { chk(cur); cur = "" }
            END { if (cur != "") chk(cur); print n + 0 }')
        if [ "$BADDIRS" -gt 0 ]; then
            fail "F5: a recursive '-a --dirs' rsync is back (copies the whole tree serially)"
        else
            pass "F5: no recursive '--dirs' rsync"
        fi
        # ---- F6: graceful SIGTERM. §8.7 also has kill -TERM 0, so the wrapper's is pinned inside its on_term.
        check_in_fn  "F6: wrapper signals its process group"            8.6 on_term 'kill -TERM 0 2>/dev/null'
        check_in_sec "F6: wrapper traps TERM/INT (else tini SIGKILLs rsync)" 8.6 'trap on_term TERM INT'
        check_order  "F6: wrapper's trap is set before the sync starts" 8.6 'trap on_term TERM INT' '/userapp/scripts/dispatch-sync.sh &'
        check_in_sec "F6: wrapper passes on a TERM that landed before the fork" 8.6 '[ -n "$GOT_TERM" ] && kill -TERM $! 2>/dev/null'
        check_in_sec "F6: wrapper keeps the sync exit code on a late TERM (not 143)" 8.6 "trap 'exit \"\$SYNC_EXIT\"' TERM INT"
        check_in_sec "F6: wrapper still quits the sidecar without nas-sync-lib.sh (else the pod hangs NotReady)" 8.6 'wait_child() { wait "$1"; WAIT_RC=$?; }'
        check_in_sec "F6: dispatcher waits for the mode script"         8.5 'wait_child "$CHILD"'
        check_in_sec "F6: entrypoint waits for the initial sync"        8.7 'wait_child "$INIT_PID"'
        check_in_sec "F6: entrypoint waits for cron and its runs"       8.7 'wait_child "$CRON_PID"'
        # A command, not prose: comments explain why it is gone.
        guide_code | has_pin 'exec cron'
        case "$?" in
            0) fail "F6: the Deployment entrypoint execs cron again (cron-launched runs lose SIGTERM)" ;;
            1) pass "F6: entrypoint does not exec cron" ;;
            *) fail "F6: entrypoint does not exec cron — $BADPIN" ;;
        esac
        # One terminationGracePeriodSeconds: 60 per client pod spec, in the YAML of its own section.
        check_each_pod_spec "F6: grace period" "F6: terminationGracePeriodSeconds: 60" "terminationGracePeriodSeconds: 60"
        # §8.7 shutdown fixes that only the slow runtime suite covers otherwise.
        check_in_sec "F6: §8.7 traps TERM/INT (else tini SIGKILLs the runs)" 8.7 'trap on_term TERM INT'
        check_order  "F6: §8.7 trap is set before the initial sync starts" 8.7 'trap on_term TERM INT' 'dispatch-sync.sh &'
        check_in_fn  "F6: §8.7 on_term signals the in-flight runs"      8.7 on_term 'signal_runs'
        check_in_fn  "F6: §8.7 on_term stops cron"                      8.7 on_term '[ -n "$CRON_PID" ] && kill -TERM "$CRON_PID"'
        check_in_sec "F6: §8.7 a TERM at launch still signals the initial sync" 8.7 '[ -n "$GOT_TERM" ] && kill -TERM 0 2>/dev/null'
        check_in_sec "F6: §8.7 a TERM at launch still stops cron"       8.7 '[ -n "$GOT_TERM" ] && kill -TERM "$CRON_PID"'
        check_in_sec "F6: §8.7 drain signals each run group once (a repeat TERM loses the partial)" 8.7 'case "$SIGNALLED" in'
        check_in_sec "F6: §8.7 records signalled run groups (else TERMed on every poll)" 8.7 'SIGNALLED="$SIGNALLED$pg "'
        check_in_sec "F6: §8.7 signals the run's process group"         8.7 'kill -TERM -- "-$pg" 2>/dev/null'
        # The count alone is satisfied by a drain line moved elsewhere, so each wait is pinned to its own drain.
        check_in_sec "F6: §8.7 a TERM during the initial sync drains right after the wait" 8.7 'wait_child "$INIT_PID"' '[ -n "$GOT_TERM" ] && drain_and_exit'
        check_in_sec "F6: §8.7 a TERM during cron drains right after the wait"             8.7 'wait_child "$CRON_PID"' '[ -n "$GOT_TERM" ] && drain_and_exit'
        DRAINS=$(count_code 8.7 '[ -n "$GOT_TERM" ] && drain_and_exit')
        if [ "$DRAINS" -ge 4 ]; then
            pass "F6: §8.7 drains after a TERM at all $DRAINS waits and launches"
        else
            fail "F6: §8.7 has $DRAINS of 4 '[ -n \"\$GOT_TERM\" ] && drain_and_exit' lines (before and after the initial sync, before and after cron) — a TERM at the missing spot ends without waiting for the runs"
        fi
        # A launch guarded by a drain on the previous code line (comments and blanks are gone): a TERM before
        # the launch must not start an unbounded sync or cron. The post-wait drains do not count.
        PRELAUNCH=$(sec_code 8.7 | awk '/^(flock -n|cron -f)/ && prev ~ /^\[ -n "\$GOT_TERM" \] && drain_and_exit/ { n++ } { prev = $0 } END { print n + 0 }')
        if [ "$PRELAUNCH" -ge 2 ]; then
            pass "F6: §8.7 no launch after a TERM (initial sync and cron guarded)"
        else
            fail "F6: §8.7 pre-launch drain_and_exit guards $PRELAUNCH of 2 launches (initial sync, cron) — a TERM before launch starts a sync nobody signals"
        fi
        # ---- Dockerfiles: the CRLF guard must work under /bin/sh (dash), where $'\r' is not a carriage return.
        for s in 4.4 8.8; do
            # The whole test line: -eq instead of -ne would pass every clean file and never fire on CRLF.
            check_in_sec "Dockerfile §$s: CRLF guard counts CR bytes with tr" $s "if [ \"\$(tr -cd '\\r' < \"\$f\" | wc -c)\" -ne 0 ]; then"
            check_absent "Dockerfile §$s: no \$'\\r' in the CRLF guard (dash never fires it)" "\$'\\r'" $s
        done
        # ---- verify (§8.10): settings validated before any tier runs; rc 23 fails the run
        check_in_sec "verify: VERIFY_MODE validated (else a typo ends in VERIFY OK)" 8.10 'case "$VERIFY_MODE" in meta|checksum|both) ;; *) die "VERIFY_MODE='
        check_in_sec "verify: VERIFY_FAIL_THRESHOLD validated (else drift can end in VERIFY OK)" 8.10 "case \"\$VERIFY_FAIL_THRESHOLD\" in ''|*[!0-9]*) die \"VERIFY_FAIL_THRESHOLD="
        check_in_sec "verify: VERIFY_FAIL_THRESHOLD read as decimal (08 = octal error)" 8.10 'VERIFY_FAIL_THRESHOLD=$((10#$VERIFY_FAIL_THRESHOLD))'
        check_in_sec "verify: VERIFY_SLICES must be digits (tier 2 only)" 8.10 "case \"\$VERIFY_SLICES\" in ''|*[!0-9]*) die \"VERIFY_SLICES="
        check_in_sec "verify: VERIFY_SLICES >= 1 (0 divides by zero)" 8.10 '[ "$VERIFY_SLICES" -ge 1 ] 2>/dev/null || die "VERIFY_SLICES='
        check_in_sec "verify: VERIFY_SLICES read as decimal (08 = octal error)" 8.10 'VERIFY_SLICES=$((10#$VERIFY_SLICES))'
        check_order  "verify: VERIFY_MODE is validated before tier 1 runs" 8.10 'case "$VERIFY_MODE" in meta|checksum|both)' 'rsync $BASE_FLAGS "${REMOTE_URL}/"'
        check_order  "verify: VERIFY_FAIL_THRESHOLD is validated before tier 1 runs" 8.10 'VERIFY_FAIL_THRESHOLD=$((10#$VERIFY_FAIL_THRESHOLD))' 'rsync $BASE_FLAGS "${REMOTE_URL}/"'
        check_order  "verify: VERIFY_SLICES validated before tier 1 runs" 8.10 '[ "$VERIFY_SLICES" -ge 1 ] 2>/dev/null' 'rsync $BASE_FLAGS "${REMOTE_URL}/"'
        check_in_sec "verify: tier 1 fails on rc 23 (unreadable dir not compared)" 8.10 'if [ "$RC" -ne 0 ] && [ "$RC" -ne 24 ]; then'
        check_in_sec "verify: tier-2 rc 23 tolerated only with the link_stat line" 8.10 "! grep -q 'link_stat" "|| grep -v -e '^rsync error: '"
        check_in_sec "verify: tier-2 rc 23 with any other output fails the run" 8.10 '"${WORK_DIR}/ck.err" | grep -q .; then'
        check_in_sec "verify: any other tier-2 rc 23 fails the run with 23" 8.10 'die "verify aborted" 23'
        # ---- MANIFEST_MAX_AGE / CHUNK_MAX_AGE: a non-number made the staleness test an error, i.e. false
        for v in "8.4 MANIFEST_MAX_AGE" "8.3 CHUNK_MAX_AGE"; do
            read -r s var <<< "$v"
            check_in_sec "$var validated (a non-number turns the staleness guard off)" "$s" "if case \"\$$var\" in" "''|*[!0-9]*) false ;;"
            check_in_sec "$var read as decimal (08 = octal error)" "$s" "$var=\$((10#\$$var))"
            check_order  "$var: its validation comes before the staleness test" "$s" "$var=\$((10#\$$var))" "\"\$AGE\" -gt \"\$$var\""
            check_in_sec "$var falls back to 86400 with a WARN" "$s" "log \"WARN: $var=" "$var=86400"
        done
        # ---- F7: status file
        check_in_sec "F7: status records interruptions"                 8.5 '${INTERRUPTED:+ interrupted=TERM}'
        # ---- The v3.15 invariants of section 9, once per place that needs them. Section 9 greps the whole
        # guide (v3.15 must pass it too), so the other copies keep it green when one of several is lost.
        check_each_pod_spec "B1: Istio proxy-start annotation" "B1: proxy.istio.io/config holdApplicationUntilProxyStarts annotation" "proxy.istio.io/config: '{\"holdApplicationUntilProxyStarts\": true}'"
        for s in 8.2 8.3 8.4 8.10; do
            check_in_sec "B1: §$s pre-flight retries before it syncs (wait_for_remote)" $s 'wait_for_remote || die "Remote not reachable'
        done
        for s in 8.2 8.3 8.4; do
            check_in_sec "A6: §$s keeps partial files out of the tree (--partial-dir)" $s '--partial-dir=.rsync-partial'
        done
        check_in_sec "B2: §8.2 treats rsync rc 23/24 as success"        8.2 'rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC'
        check_in_sec "B2: §8.3 treats rsync rc 23/24 as success"        8.3 'if ! rsync_rc_ok "$rc"; then'
        RCOK=$(count_code 8.4 'rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC')
        if [ "$RCOK" -ge 2 ]; then
            pass "B2: §8.4 treats rsync rc 23/24 as success (manifest run and full-sync fallback)"
        else
            fail "B2: §8.4 treats rsync rc 23/24 as success (manifest run and full-sync fallback) — $RCOK of 2 'rsync_rc_ok \"\$RC\" && SYNC_EXIT=0 || SYNC_EXIT=\$RC' lines in the code"
        fi
        check_in_sec "B3: §8.7 cron runs are flock-guarded"             8.7 '${CRON_SCHEDULE} root . /etc/environment && flock -n /var/lock/nas-sync.lock'
        check_in_sec "B3: §8.7 the initial sync takes the same lock"    8.7 'flock -n /var/lock/nas-sync.lock /userapp/scripts/dispatch-sync.sh &'
        check_in_sec "B6: §8.5 status files live in .nas-sync-status"   8.5 'STATUS_DIR="${STATUS_DIR:-${LOCAL_NAS_PATH}/.nas-sync-status}"'
        check_in_sec "verify mode: §8.10 prints the VERIFY RESULT line" 8.10 'echo "VERIFY RESULT mode='
        check_in_sec "chunked reconcile: §4.6 writes chunks.meta"       4.6 '> "${TMP_DIR}/chunks.meta"'
        check_in_sec "chunked reconcile: §8.3 reads chunks.meta"        8.3 'meta="${CHUNK_DIR}/chunks.meta"'
        for s in 4.3 4.6; do
            check_in_sec "A5: §$s prunes .snapshot at every depth"      $s "-name '.snapshot'"
        done
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
