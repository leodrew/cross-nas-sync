# Multi-Target Incremental Sync (v3.14) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce `cross-cluster-rsync-guide-v3.14-consolidated.md` — a standalone, follow-along guide that extends the v3.13 cross-cluster rsync system so one source NAS B can feed many target NAS clusters, each pulling its own per-client incremental manifest.

**Architecture:** v3.14 is a verbatim copy of v3.13 with additive edits. One source rsync daemon (unchanged) plus one multi-client manifest generator that does a single `find` walk and fans out per-client manifests by a stateless lookback window. Each target cluster runs the existing client image with a unique `CLIENT_ID` and fetches only its own manifest. A client-registry ConfigMap on Cluster B is the single place targets are listed.

**Tech Stack:** Markdown (the deliverable). Embedded artifacts: Bash (generator + client scripts), GNU `find`/`awk`, Kubernetes/Istio YAML, Docker. Verification uses the Bash tool (Git Bash on Windows) to functionally test the embedded Bash scripts and structurally check YAML.

## Global Constraints

Copied verbatim from the design spec (`docs/superpowers/specs/2026-06-20-multi-target-incremental-sync-design.md`). Every task implicitly includes these:

- Port **8787**; namespace **`ea-pmc`**; **delete disabled** — never add `--delete`.
- **Console-only logging**; rsync uses **`--whole-file`**.
- **Sidecar-quit** for CronJob/Job pods; Deployment pods do NOT quit the sidecar.
- **CRLF guards**: Dockerfiles run `dos2unix` and FAIL the build on any remaining CR; every fenced shell script in the guide must be LF-only and start with `#!/bin/bash` (no trailing `^M`).
- `reverse lookup = no` in `rsyncd.conf`.
- ConfigMaps/Secrets mounted via **`subPath`** (single-file mounts); read-only mounts never `chmod`-ed.
- `[nas-data]` rsyncd module stays **`read only = yes`**; `.nas-sync-state/` stays excluded **client-side** (`rsync-exclude.txt`) but NOT in the server `exclude =`.
- The change-window model is **stateless per-client lookback** (no marker files).
- Manifest generation is **one `find` walk total**, independent of target count.
- Placeholders `your-registry.example.com` and `ISTIO_EXTERNAL_IP_HERE` and `◄ MODIFY` markers are left intact in copied blocks.
- **Do NOT renumber existing top-level sections (§1–§14).** All new content is a subsection (e.g. §6.2, §9A.3) or an appendix. This preserves the doc's internal cross-references.

**Canonical paths used throughout:**
- Source guide: `cross-cluster-rsync-guide-v3.13-consolidated.md`
- New guide (the deliverable): `cross-cluster-rsync-guide-v3.14-consolidated.md`
- Per-client manifest on source NAS: `.nas-sync-state/clients/<CLIENT_ID>/sync-manifest.txt`
- Registry file inside the generator pod: `/userapp/config/clients.txt`

---

## Task 1: Create v3.14 guide from v3.13 + version bump

**Files:**
- Create: `cross-cluster-rsync-guide-v3.14-consolidated.md` (copy of v3.13)
- Read: `cross-cluster-rsync-guide-v3.13-consolidated.md`

**Interfaces:**
- Produces: the file `cross-cluster-rsync-guide-v3.14-consolidated.md`, byte-identical to v3.13 except: the title line says `v3.14`, and all image tags `:3.13` → `:3.14`. All later tasks edit THIS file.

- [ ] **Step 1: Copy the v3.13 file to the v3.14 filename**

Run (Bash tool):
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
cp cross-cluster-rsync-guide-v3.13-consolidated.md cross-cluster-rsync-guide-v3.14-consolidated.md
```

- [ ] **Step 2: Verify the copy is byte-identical**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
diff -q cross-cluster-rsync-guide-v3.13-consolidated.md cross-cluster-rsync-guide-v3.14-consolidated.md && echo IDENTICAL
```
Expected: `IDENTICAL`

- [ ] **Step 3: Bump the title line** (Edit on the v3.14 file)

Replace:
```
# Cross-Cluster NAS Rsync — Consolidated Guide v3.13
```
with:
```
# Cross-Cluster NAS Rsync — Consolidated Guide v3.14 (Multi-Target)
```

- [ ] **Step 4: Bump image tags** (Edit on the v3.14 file, `replace_all: true` for each)

- Replace all `nas-sync-server:3.13` → `nas-sync-server:3.14`
- Replace all `nas-sync-client:3.13` → `nas-sync-client:3.14`
- Replace all `LABEL version="3.13"` → `LABEL version="3.14"`

(Leave every other `v3.13` / `3.13` occurrence — historical references and the "What This Consolidates" table — for Task 7. Prose still mentioning v3.13 here is expected and fine at this stage.)

- [ ] **Step 5: Verify the tag bump took and nothing else changed structurally**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -c 'nas-sync-server:3.14' cross-cluster-rsync-guide-v3.14-consolidated.md
grep -c 'nas-sync-client:3.14' cross-cluster-rsync-guide-v3.14-consolidated.md
grep -n ':3.13' cross-cluster-rsync-guide-v3.14-consolidated.md || echo "no stray :3.13 image tags"
```
Expected: server count ≥ 2, client count ≥ 3, and `no stray :3.13 image tags`.

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
Scaffold v3.14 guide from v3.13 (version bump)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Multi-client manifest generator (script + server Dockerfile)

Replaces the single-client `generate-manifest.sh` (§4.3) with `generate-manifests.sh`, and updates the server image build (§4.4, §4.5) for the new filename. The generator does ONE walk and fans out per-client manifests by lookback window.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.14-consolidated.md` (§4.3 script, §4.4 Dockerfile, §4.5 build)
- Test (temp, not committed): `$(mktemp -d)/generate-manifests.sh` + harness

**Interfaces:**
- Produces (the embedded script `generate-manifests.sh`):
  - Reads env `SOURCE_PATH` (default `/mnt/nas-source`), `STATE_DIR` (default `${SOURCE_PATH}/.nas-sync-state`), `REGISTRY_FILE` (default `/userapp/config/clients.txt`).
  - Registry format: lines `<client_id> <lookback_hours>`; blank lines and `#`-comments ignored.
  - Writes `${STATE_DIR}/clients/<id>/sync-manifest.txt` (relative `%P` paths) + `${STATE_DIR}/clients/<id>/manifest.meta` (`generated_at`, `window_threshold_epoch`, `file_count`), published via atomic `mv` from `.tmp`.
- Consumed by: Task 3 (CronJob runs it, mounts the registry at `/userapp/config/clients.txt`), Task 4 (client reads `clients/<id>/sync-manifest.txt`).

- [ ] **Step 1: Write the generator script + a failing functional test to a temp sandbox**

This is the single source for the script. Paste it identically into the temp file here AND into the guide in Step 4.

Run (Bash tool) — creates the sandbox, the script, and the test harness:
```bash
SBX="$(mktemp -d)"; echo "SANDBOX=$SBX"
cat > "$SBX/generate-manifests.sh" <<'SCRIPT'
#!/bin/bash
#############################################
# Multi-Client Manifest Generator (Cluster B) — v3.14
# ONE find walk; fan-out per-client manifests by a
# stateless lookback window. No markers, no per-client walk.
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

mkdir -p "$CLIENTS_DIR"
NOW=$(date +%s)

log "========================================"
log "Multi-Client Manifest Generator v3.14"
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
    : > "${CLIENTS_DIR}/${CID}/sync-manifest.txt.tmp"
    CLIENT_IDS+=("$CID"); THRESHOLDS+=("$THRESH")
    log "  client=$CID lookback=${HOURS}h threshold=$THRESH"
done < "$REGISTRY_FILE"

[ "${#CLIENT_IDS[@]}" -gt 0 ] || { log "ERROR: no valid clients in registry"; exit 1; }

# awk config: one line per client => id<TAB>threshold<TAB>tmpfile
AWK_CONF="$(mktemp)"
i=0
while [ "$i" -lt "${#CLIENT_IDS[@]}" ]; do
    printf '%s\t%s\t%s\n' "${CLIENT_IDS[$i]}" "${THRESHOLDS[$i]}" \
        "${CLIENTS_DIR}/${CLIENT_IDS[$i]}/sync-manifest.txt.tmp" >> "$AWK_CONF"
    i=$((i+1))
done

log "Walking source (one pass)..."
find "$SOURCE_PATH" \
    -path "$SOURCE_PATH/.snapshot" -prune -o \
    -path "$STATE_DIR" -prune -o \
    -type f -printf '%T@ %P\n' 2>/dev/null \
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

# Publish atomically + write meta.
i=0
while [ "$i" -lt "${#CLIENT_IDS[@]}" ]; do
    CID="${CLIENT_IDS[$i]}"
    TMP="${CLIENTS_DIR}/${CID}/sync-manifest.txt.tmp"
    FINAL="${CLIENTS_DIR}/${CID}/sync-manifest.txt"
    COUNT=$(wc -l < "$TMP" 2>/dev/null | tr -d ' '); [ -n "$COUNT" ] || COUNT=0
    mv -f "$TMP" "$FINAL"
    printf 'generated_at=%s\nwindow_threshold_epoch=%s\nfile_count=%s\n' \
        "$NOW" "${THRESHOLDS[$i]}" "$COUNT" > "${CLIENTS_DIR}/${CID}/manifest.meta"
    log "  wrote $FINAL ($COUNT files)"
    i=$((i+1))
done

log "Done."
SCRIPT

cat > "$SBX/test.sh" <<'TEST'
#!/bin/bash
set -u
SBX="$1"
SRC="$SBX/src"
rm -rf "$SRC"; mkdir -p "$SRC/sub" "$SRC/.snapshot" "$SRC/.nas-sync-state/clients"
echo x > "$SRC/recent.txt";          touch -d '1 hour ago'    "$SRC/recent.txt"
echo x > "$SRC/sub/mid.txt";         touch -d '10 hours ago'  "$SRC/sub/mid.txt"
echo x > "$SRC/old.txt";             touch -d '100 hours ago' "$SRC/old.txt"
echo x > "$SRC/.snapshot/snap.txt";  touch -d '1 hour ago'    "$SRC/.snapshot/snap.txt"
echo x > "$SRC/.nas-sync-state/state.txt"; touch -d '1 hour ago' "$SRC/.nas-sync-state/state.txt"
cat > "$SBX/clients.txt" <<EOF
# id    hours
fast    6
slow    48
EOF
SOURCE_PATH="$SRC" STATE_DIR="$SRC/.nas-sync-state" REGISTRY_FILE="$SBX/clients.txt" \
    bash "$SBX/generate-manifests.sh"
FAST="$SRC/.nas-sync-state/clients/fast/sync-manifest.txt"
SLOW="$SRC/.nas-sync-state/clients/slow/sync-manifest.txt"
fail(){ echo "FAIL: $1"; exit 1; }
[ -f "$FAST" ] || fail "no fast manifest"
[ -f "$SLOW" ] || fail "no slow manifest"
grep -qx 'recent.txt'  "$FAST" || fail "fast missing recent.txt"
grep -qx 'sub/mid.txt' "$FAST" && fail "fast must NOT contain mid.txt"
grep -qx 'old.txt'     "$FAST" && fail "fast must NOT contain old.txt"
grep -qx 'recent.txt'  "$SLOW" || fail "slow missing recent.txt"
grep -qx 'sub/mid.txt' "$SLOW" || fail "slow missing mid.txt"
grep -qx 'old.txt'     "$SLOW" && fail "slow must NOT contain old.txt"
grep -rq 'snap.txt'  "$FAST" "$SLOW" && fail ".snapshot leaked"
grep -rq 'state.txt' "$FAST" "$SLOW" && fail ".nas-sync-state leaked"
ls "$SRC/.nas-sync-state/clients/fast/"*.tmp 2>/dev/null && fail ".tmp left behind"
grep -qx 'file_count=1' "$SRC/.nas-sync-state/clients/fast/manifest.meta" || fail "fast meta count != 1"
grep -qx 'file_count=2' "$SRC/.nas-sync-state/clients/slow/manifest.meta" || fail "slow meta count != 2"
echo "ALL PASS"
TEST
echo "files written under $SBX"
```

- [ ] **Step 2: Run the test to confirm the script behaves correctly**

Run (use the `SANDBOX=` path printed above as `$SBX`):
```bash
bash "$SBX/test.sh" "$SBX"
```
Expected: ends with `ALL PASS`. (If `touch -d`, `find -printf`, or `awk` behave oddly, you are in Git Bash; the production image is `ubuntu:24.04` where all are GNU/standard — the script is correct for production regardless.)

- [ ] **Step 3: Replace the §4.3 script block in the guide** (Edit on v3.14 file)

Replace the §4.3 header + fenced block. Find this block:
```
### 4.3 File: `cluster-b/scripts/generate-manifest.sh`

> Used only for `incremental` mode. Produces the changed-file list.
```
Replace its header/intro with:
```
### 4.3 File: `cluster-b/scripts/generate-manifests.sh`

> Used only for `incremental` mode. One `find` walk → per-client manifests by
> stateless lookback window. The set of clients (and each client's lookback hours)
> comes from the registry ConfigMap mounted at `/userapp/config/clients.txt` (§6.2).

```
Then replace the entire fenced `bash` body that currently starts with `#!/bin/bash` / `# Manifest Generator (Cluster B)` and ends at `log "Manifest written to $MANIFEST. Done."` (the closing ``` line stays) with the exact `generate-manifests.sh` content from Step 1 (the text between the `<<'SCRIPT'` and `SCRIPT` markers, without those markers).

- [ ] **Step 4: Update the server Dockerfile (§4.4) for the new filename** (Edit on v3.14 file, four edits)

1. Replace `COPY generate-manifest.sh /userapp/scripts/generate-manifest.sh`
   with `COPY generate-manifests.sh /userapp/scripts/generate-manifests.sh`
2. Replace `RUN dos2unix /entrypoint.sh /userapp/scripts/generate-manifest.sh \`
   with `RUN dos2unix /entrypoint.sh /userapp/scripts/generate-manifests.sh \`
3. Replace `    && chmod +x /entrypoint.sh /userapp/scripts/generate-manifest.sh`
   with `    && chmod +x /entrypoint.sh /userapp/scripts/generate-manifests.sh`
4. Replace `RUN for f in /entrypoint.sh /userapp/scripts/generate-manifest.sh; do \`
   with `RUN for f in /entrypoint.sh /userapp/scripts/generate-manifests.sh; do \`

- [ ] **Step 5: Update the build step (§4.5)** (Edit on v3.14 file)

Replace:
```
sed -i 's/\r$//' entrypoint.sh generate-manifest.sh 2>/dev/null || true
```
with:
```
sed -i 's/\r$//' entrypoint.sh generate-manifests.sh 2>/dev/null || true
```

- [ ] **Step 6: Verify the guide no longer references the old single-client filename**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -n 'generate-manifest\.sh' cross-cluster-rsync-guide-v3.14-consolidated.md || echo "no old filename references"
grep -c 'generate-manifests.sh' cross-cluster-rsync-guide-v3.14-consolidated.md
```
Expected: `no old filename references`, and the `generate-manifests.sh` count ≥ 5.

- [ ] **Step 7: Confirm the embedded script is LF-only (CRLF guard)**

Run (extracts the first shebang line of the §4.3 block and checks for `^M`):
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -n $'\r' cross-cluster-rsync-guide-v3.14-consolidated.md && echo "CRLF FOUND" || echo "LF clean"
```
Expected: `LF clean`.

- [ ] **Step 8: Commit + clean sandbox**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
v3.14: multi-client manifest generator (single-walk fan-out)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
rm -rf "$SBX"
```

---

## Task 3: Client-registry ConfigMap + generator CronJob (§6)

Replaces §6 (single-client `cronjob-manifest.yaml`) with §6.1 `cronjob-manifests.yaml` (mounts the registry, runs the new script) and adds §6.2 the registry ConfigMap.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.14-consolidated.md` (§6)
- Test (temp): `$(mktemp -d)/manifest.yaml`

**Interfaces:**
- Consumes: `generate-manifests.sh` (Task 2) at `/userapp/scripts/generate-manifests.sh`; registry format `<client_id> <lookback_hours>`.
- Produces: registry file mounted at `/userapp/config/clients.txt` (consumed by Task 2's `REGISTRY_FILE` default).

- [ ] **Step 1: Write the new §6 YAML to a temp file and validate it**

Run (Bash tool):
```bash
SBX="$(mktemp -d)"; echo "SANDBOX=$SBX"
cat > "$SBX/manifest.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nas-sync-clients
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: manifest
data:
  clients.txt: |
    # <client_id>  <lookback_hours>
    # lookback = client pull period x2-3 (or pull period + worst tolerated outage).
    # Add one line per target cluster; remove a line to retire a target.
    nas-a   6
    nas-c   6
    nas-d   48
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nas-sync-manifest
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: manifest
spec:
  # Run ~10 min BEFORE the most-frequent client incremental sync.
  schedule: "50 */2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 86400
      template:
        metadata:
          annotations:
            sidecar.istio.io/inject: "false"
        spec:
          containers:
            - name: manifest-gen
              image: your-registry.example.com/nas-sync-server:3.14   # ◄ reuse server image
              command: ["/bin/bash", "/userapp/scripts/generate-manifests.sh"]
              env:
                - name: SOURCE_PATH
                  value: "/mnt/nas-source"
                - name: STATE_DIR
                  value: "/mnt/nas-source/.nas-sync-state"
                - name: REGISTRY_FILE
                  value: "/userapp/config/clients.txt"
              volumeMounts:
                - name: nas-source
                  mountPath: /mnt/nas-source
                - name: clients-registry
                  mountPath: /userapp/config/clients.txt
                  subPath: clients.txt
                  readOnly: true
          restartPolicy: Never
          volumes:
            - name: nas-source
              nfs:
                server: "10.90.220.155"          # ◄ MODIFY
                path: "/PMCenterData"            # ◄ MODIFY
                readOnly: false                  # REQUIRED: manifests are written here
            - name: clients-registry
              configMap:
                name: nas-sync-clients
YAML
echo "wrote $SBX/manifest.yaml"
```

- [ ] **Step 2: Validate the YAML (structure + key invariants)**

Run:
```bash
fail(){ echo "FAIL: $1"; exit 1; }
F="$SBX/manifest.yaml"
command -v python3 >/dev/null 2>&1 && python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1]))); print('YAML parses')" "$F" || echo "python3/pyyaml unavailable — relying on grep checks"
grep -q 'subPath: clients.txt'        "$F" || fail "registry not mounted via subPath"
grep -q 'readOnly: false'             "$F" || fail "nas-source must be rw (manifests written here)"
grep -q 'generate-manifests.sh'       "$F" || fail "wrong generator script"
grep -q 'name: nas-sync-clients'      "$F" || fail "registry ConfigMap missing"
echo "STRUCTURE OK"
```
Expected: `STRUCTURE OK` (and `YAML parses` if python3+pyyaml present).

- [ ] **Step 3: Replace §6 in the guide** (Edit on v3.14 file)

Replace the §6.1 header + intro. Find:
```
### 6.1 cronjob-manifest.yaml
```
Replace with:
```
### 6.1 cronjob-manifests.yaml + client registry
```
Then replace the entire fenced `yaml` block under §6.1 (the one beginning `apiVersion: batch/v1` / `kind: CronJob` / `name: nas-sync-manifest` and ending at `readOnly: false                  # REQUIRED: manifest + state are written here`) with the full YAML from Step 1 (the text between `<<'YAML'` and `YAML`).

- [ ] **Step 4: Update the §6.1 apply note + add a §6.2 explainer** (Edit on v3.14 file)

Replace:
```
```bash
# Only if using incremental mode:
kubectl apply -f cluster-b/cronjob-manifest.yaml
```
```
with:
```
```bash
# Only if using incremental mode (applies both the registry ConfigMap and the CronJob):
kubectl apply -f cluster-b/cronjob-manifests.yaml
```

### 6.2 The client registry (`clients.txt`)

The `nas-sync-clients` ConfigMap is the **single source of truth** for which targets
exist. Each non-comment line is `<client_id> <lookback_hours>`:

- **`client_id`** must match the `CLIENT_ID` env on that target's client (§9A.3). It
  names the per-client manifest directory `.nas-sync-state/clients/<client_id>/`.
- **`lookback_hours`** = that client's pull period × 2–3 (e.g. a 2h CronJob → `6`; a
  daily puller → `48`). The generator emits "files changed in the last N hours", so
  overlapping windows let a target that misses a cycle catch up on its next run.

Add a target = add a line (then deploy its client, §9A.3). Retire a target = delete its
line (optionally `rm -rf` its `.nas-sync-state/clients/<id>/` dir on the source NAS).
The generator does **one** `find` walk regardless of how many clients are listed.
```

- [ ] **Step 5: Verify the guide references the new names and not the old**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -n 'cronjob-manifest\.yaml' cross-cluster-rsync-guide-v3.14-consolidated.md || echo "no old cronjob filename"
grep -c 'nas-sync-clients' cross-cluster-rsync-guide-v3.14-consolidated.md
grep -c '### 6.2' cross-cluster-rsync-guide-v3.14-consolidated.md
```
Expected: `no old cronjob filename`; `nas-sync-clients` ≥ 2; `### 6.2` = 1.

- [ ] **Step 6: Commit + clean sandbox**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
v3.14: client-registry ConfigMap + multi-client generator CronJob (§6)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
rm -rf "$SBX"
```

---

## Task 4: Client incremental script — per-client manifest by CLIENT_ID (§8.4)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.14-consolidated.md` (§8.4 `nas-sync-incremental.sh`)
- Test (temp): a small snippet validating the derivation logic

**Interfaces:**
- Consumes: env `CLIENT_ID`; the per-client path `.nas-sync-state/clients/<CLIENT_ID>/sync-manifest.txt` from Task 2.
- Produces: client fetches its own manifest; behavior otherwise unchanged (FULL fallback if missing, skip if empty).

- [ ] **Step 1: Write a failing test for the derivation logic**

Run (Bash tool):
```bash
SBX="$(mktemp -d)"; echo "SANDBOX=$SBX"
cat > "$SBX/derive.sh" <<'SCRIPT'
#!/bin/bash
# Mirrors the §8.4 derivation block under test.
CLIENT_ID="${CLIENT_ID:-}"
if [ -n "$CLIENT_ID" ]; then
    MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/clients/${CLIENT_ID}/sync-manifest.txt}"
else
    MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"
fi
echo "$MANIFEST_NAME"
SCRIPT
cat > "$SBX/test.sh" <<'TEST'
#!/bin/bash
set -u
SBX="$1"; fail(){ echo "FAIL: $1"; exit 1; }
out=$(CLIENT_ID=nas-c bash "$SBX/derive.sh")
[ "$out" = ".nas-sync-state/clients/nas-c/sync-manifest.txt" ] || fail "CLIENT_ID set: got '$out'"
out=$(bash "$SBX/derive.sh")
[ "$out" = ".nas-sync-state/sync-manifest.txt" ] || fail "CLIENT_ID unset: got '$out'"
out=$(CLIENT_ID=nas-c MANIFEST_NAME=custom/path.txt bash "$SBX/derive.sh")
[ "$out" = "custom/path.txt" ] || fail "explicit override: got '$out'"
echo "ALL PASS"
TEST
bash "$SBX/test.sh" "$SBX"
```
Expected: `ALL PASS` (this validates the exact logic before embedding).

- [ ] **Step 2: Edit §8.4 — replace the single MANIFEST_NAME line** (Edit on v3.14 file)

Replace:
```
MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"
```
with:
```
# Per-client manifest path (multi-target). CLIENT_ID must match a registry line (§6.2).
CLIENT_ID="${CLIENT_ID:-}"
if [ -n "$CLIENT_ID" ]; then
    MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/clients/${CLIENT_ID}/sync-manifest.txt}"
else
    MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"
fi
```

- [ ] **Step 3: Edit §8.4 — surface CLIENT_ID in the start log** (Edit on v3.14 file)

Replace:
```
log "=== NAS SYNC (incremental) ==="
```
with:
```
log "=== NAS SYNC (incremental) client=${CLIENT_ID:-<legacy>} ==="
```

- [ ] **Step 4: Verify the §8.4 block parses as Bash and contains the derivation**

Run (extract requires no tooling — just confirm the strings are present and balanced):
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -c 'clients/${CLIENT_ID}/sync-manifest.txt' cross-cluster-rsync-guide-v3.14-consolidated.md
grep -c 'client=${CLIENT_ID:-<legacy>}' cross-cluster-rsync-guide-v3.14-consolidated.md
```
Expected: each = 1.

- [ ] **Step 5: Commit + clean sandbox**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
v3.14: client fetches per-CLIENT_ID manifest (§8.4)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
rm -rf "$SBX"
```

---

## Task 5: Per-target deploy walkthrough (§9A.3) + CLIENT_ID env on the client CronJob

Adds the "how to stand up target #2, #3…" section and wires `CLIENT_ID` into the §9A.2 CronJob env.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.14-consolidated.md` (§9A.2 env block, new §9A.3)
- Test (temp): YAML structure check on the edited CronJob env snippet

**Interfaces:**
- Consumes: `CLIENT_ID` (Task 4), registry (Task 3), parallel-bootstrap pattern (existing §10 / §12).

- [ ] **Step 1: Add CLIENT_ID to the §9A.2 CronJob env** (Edit on v3.14 file)

Replace (the SYNC_MODE block in §9A.2 `cronjob-client.yaml`):
```
                # ===== SELECT SYNC MODE HERE =====
                - name: SYNC_MODE
                  value: "incremental"          # ◄ standard | parallel | incremental
                - name: PARALLEL_WORKERS
                  value: "6"                     # used if SYNC_MODE=parallel
                # =================================
```
with:
```
                # ===== SELECT SYNC MODE HERE =====
                - name: SYNC_MODE
                  value: "incremental"          # ◄ standard | parallel | incremental
                - name: CLIENT_ID
                  value: "nas-a"                 # ◄ MODIFY — must match a registry line (§6.2); used by incremental
                - name: PARALLEL_WORKERS
                  value: "6"                     # used if SYNC_MODE=parallel
                # =================================
```

- [ ] **Step 2: Insert the §9A.3 walkthrough** (Edit on v3.14 file)

Insert immediately BEFORE the line `## 10. Step 6B — Cluster A: Deployment (long-running)`. New content:
```
### 9A.3 Adding more target clusters (multi-target)

Each target NAS is its own cluster running this same client image, distinguished only
by `CLIENT_ID`. To add target **N** (e.g. `nas-c`):

1. **Register it** — add a line to the `nas-sync-clients` registry on Cluster B (§6.2)
   and re-apply:
   ```bash
   # cluster-b/cronjob-manifests.yaml → data.clients.txt
   #   nas-c   6
   kubectl --context cluster-b apply -f cluster-b/cronjob-manifests.yaml
   ```

2. **Deploy this target's shared resources** — copy the §9A.1 manifests, pointing the
   PV/PVC at THIS target's NAS (its IP/export/size). Keep namespace `ea-pmc`.

3. **Bootstrap with a full seed (one-time)** — a lookback manifest never lists the whole
   dataset, so a brand-new target must be seeded first. Deploy the §10 Deployment with
   `SYNC_MODE=parallel` (no time limit) and `CLIENT_ID=nas-c`; let it finish, then delete it:
   ```bash
   kubectl --context cluster-c apply -f cluster-c/deployment-client.yaml   # SYNC_MODE=parallel
   # …wait for the initial bulk sync to complete in logs…
   kubectl --context cluster-c delete -f cluster-c/deployment-client.yaml
   ```

4. **Switch to routine incremental** — deploy the §9A.2 CronJob with
   `SYNC_MODE=incremental` and `CLIENT_ID=nas-c`, scheduled AFTER the generator
   (the generator runs at `50 */2 * * *`; a client at `0 */2 * * *` pulls 10 min later).

5. **Add the weekly reconcile** — a second CronJob with `SYNC_MODE=parallel` (e.g.
   `0 3 * * 0`) and the same `CLIENT_ID`, per §12. This backstops any change older than
   the client's lookback window.

> `REMOTE_HOST` for every target is the **same** source — Cluster B's Istio external IP
> (`ISTIO_EXTERNAL_IP_HERE`). Targets differ only by `CLIENT_ID`, their local NAS PV/PVC,
> and their registry lookback. The source rsync daemon and generator are shared, unchanged.

```

- [ ] **Step 3: Validate the edited CronJob env still parses + has CLIENT_ID**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
F=cross-cluster-rsync-guide-v3.14-consolidated.md
command -v python3 >/dev/null 2>&1 && python3 - "$F" <<'PY' || echo "python3/pyyaml unavailable — grep only"
import re,sys,yaml
t=open(sys.argv[1],encoding="utf-8").read()
# extract the cronjob-client.yaml block (first yaml fence after '### 9A.2')
seg=t.split('### 9A.2',1)[1]
block=re.search(r"```yaml\n(.*?)\n```",seg,re.S).group(1)
yaml.safe_load(block); print("9A.2 CronJob YAML parses")
PY
grep -c 'name: CLIENT_ID' "$F"
grep -c '### 9A.3' "$F"
```
Expected: `name: CLIENT_ID` ≥ 1; `### 9A.3` = 1 (and "parses" if python available).

- [ ] **Step 4: Commit**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
v3.14: per-target deploy walkthrough (§9A.3) + CLIENT_ID on client CronJob

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Per-client verify + troubleshooting (§7, §11, §13)

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.14-consolidated.md` (§7 server verify, §13 troubleshooting; §11 if a verify step fits)

**Interfaces:**
- Consumes: per-client manifest layout (Task 2), registry (Task 3).

- [ ] **Step 1: Add a per-client manifest check to §7 (server verify)** (Edit on v3.14 file)

Replace:
```
nc -zv ${ISTIO_EXTERNAL_IP} 8787
```
with:
```
nc -zv ${ISTIO_EXTERNAL_IP} 8787

# (incremental) confirm a manifest exists per registered client:
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  sh -c 'for d in /mnt/nas-source/.nas-sync-state/clients/*/; do \
    echo "$d: $(wc -l < "$d/sync-manifest.txt" 2>/dev/null || echo MISSING) files"; done'
```

- [ ] **Step 2: Replace the "Incremental: manifest not found" troubleshooting block (§13)** (Edit on v3.14 file)

Replace:
```
### Incremental: manifest not found

```bash
# Check manifest job ran and wrote the file
kubectl logs job/<manifest-job> -n ea-pmc
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.nas-sync-state/
```
```
with:
```
### Incremental: manifest not found / client degraded to full sync

A client logs `Manifest fetch failed — FULL sync fallback` when its
`clients/<CLIENT_ID>/sync-manifest.txt` is missing. Common causes:

```bash
# 1. Is CLIENT_ID registered? It must appear in the registry ConfigMap:
kubectl --context cluster-b get configmap nas-sync-clients -n ea-pmc -o yaml | grep -A20 clients.txt

# 2. Did the generator run and write that client's manifest?
kubectl --context cluster-b logs job/<manifest-job> -n ea-pmc
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.nas-sync-state/clients/<CLIENT_ID>/

# 3. Does the client's CLIENT_ID env match the registry id exactly?
kubectl --context cluster-c get cronjob nas-sync-client -n ea-pmc \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -A1 CLIENT_ID
```

Fix: add the missing line to the registry (§6.2), re-apply `cronjob-manifests.yaml`, and
wait for the next generator run. A new target also needs its one-time `parallel` bootstrap
(§9A.3 step 3) — incremental alone never seeds the full dataset.
```

- [ ] **Step 3: Verify the edits landed**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
F=cross-cluster-rsync-guide-v3.14-consolidated.md
grep -c '.nas-sync-state/clients/\*/' "$F"
grep -c 'client degraded to full sync' "$F"
```
Expected: each ≥ 1.

- [ ] **Step 4: Commit**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
v3.14: per-client verify + troubleshooting (§7, §13)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Intro, §14 checklist, "What This Consolidates", migration appendix

Ties the doc together: explains the multi-target model up front, updates the file checklist and provenance table, and adds the v3.13→v3.14 migration appendix.

**Files:**
- Modify: `cross-cluster-rsync-guide-v3.14-consolidated.md` (top banner/§1, §14, "What This Consolidates", new appendix at EOF)

- [ ] **Step 1: Extend the top banner** (Edit on v3.14 file)

Replace:
```
> **Port:** 8787 | **Delete:** Disabled | **Logging:** Console only | **Namespace:** ea-pmc
```
with:
```
> **Port:** 8787 | **Delete:** Disabled | **Logging:** Console only | **Namespace:** ea-pmc
>
> **v3.14 adds multi-target:** one source NAS B feeds many target clusters. The manifest
> generator does one `find` walk and fans out a **per-client manifest** (keyed by
> `CLIENT_ID`) using a stateless **lookback window** — no markers, source stays read-only.
> Targets are listed in one registry ConfigMap (§6.2); add a target by adding a line (§9A.3).
> See the migration appendix to move an existing v3.13 single-target deployment forward.
```

- [ ] **Step 2: Add a multi-target note to §1** (Edit on v3.14 file)

Replace:
```
Both combine freely. E.g. CronJob+incremental for routine, Deployment+parallel for bulk.
```
with:
```
Both combine freely. E.g. CronJob+incremental for routine, Deployment+parallel for bulk.

**Multi-target (v3.14):** a third axis — `CLIENT_ID` — selects which per-client manifest a
target pulls. One source daemon + one generator serve all targets; each target is its own
cluster differing only by `CLIENT_ID`, its local NAS, and its registry lookback (§6.2, §9A.3).
```

- [ ] **Step 3: Update the §14 Cluster B checklist** (Edit on v3.14 file)

Replace:
```
├── cronjob-manifest.yaml           # 6.1  (incremental only)
└── scripts/
    ├── Dockerfile                  # 4.4  (CRLF-safe)
    ├── entrypoint.sh              # 4.2
    └── generate-manifest.sh       # 4.3  (incremental only)
```
with:
```
├── cronjob-manifests.yaml          # 6.1  (incremental only: registry ConfigMap + CronJob)
└── scripts/
    ├── Dockerfile                  # 4.4  (CRLF-safe)
    ├── entrypoint.sh              # 4.2
    └── generate-manifests.sh      # 4.3  (incremental only: multi-client fan-out)
```

- [ ] **Step 4: Update the §14 Deploy Order** (Edit on v3.14 file)

Replace:
```
3. (incremental only) Deploy manifest CronJob (Step 3)
```
with:
```
3. (incremental only) Deploy registry + manifest CronJob (Step 3 / §6.2)
```
And replace:
```
8. Verify & test                              (Step 7)
```
with:
```
8. Verify & test                              (Step 7)
9. (multi-target) Repeat 6–8 per extra target, distinct CLIENT_ID  (§9A.3)
```

- [ ] **Step 5: Update "What This Consolidates"** (Edit on v3.14 file)

Replace the table header:
```
| Capability | Source Version | Status in v3.13 |
|-----------|----------------|-----------------|
```
with:
```
| Capability | Source Version | Status in v3.14 |
|-----------|----------------|-----------------|
```
Then replace the last existing row:
```
| Manifest state on source NAS (no PVC) | (this request) | ✓ (§6) |
```
with:
```
| Manifest state on source NAS (no PVC) | v3.13 | ✓ (§6) |
| Single-target incremental (one marker) | v3.13 | superseded by multi-target |
| Multi-target: per-client manifests | v3.14 | ✓ (§6.1, §8.4) |
| Stateless lookback window (no markers) | v3.14 | ✓ (§4.3, §6.2) |
| Single-walk fan-out generator | v3.14 | ✓ (§4.3) |
| Client registry ConfigMap | v3.14 | ✓ (§6.2) |
| Per-target deploy walkthrough | v3.14 | ✓ (§9A.3) |
```

- [ ] **Step 6: Append the migration appendix at EOF** (Edit on v3.14 file)

Append to the very end of the file:
```

---

## Appendix: Migrating v3.13 (single-target) → v3.14 (multi-target)

The existing single client keeps working; cut it over to the per-client model:

1. **Rebuild the server image** (`:3.14`) so `generate-manifests.sh` replaces the old
   `generate-manifest.sh` (§4.3–§4.5), and rebuild/redeploy nothing else on the source
   except the manifest CronJob.
2. **Create the registry** with your existing client as `nas-a` (§6.2). Pick its lookback
   from its current schedule (2h CronJob → `6`).
3. **Replace** `cronjob-manifest.yaml` with `cronjob-manifests.yaml` (§6.1) and apply.
   The generator now writes `.nas-sync-state/clients/nas-a/sync-manifest.txt`.
4. **Add `CLIENT_ID=nas-a`** to the existing client CronJob (§9A.2) and apply. It now
   fetches the per-client path instead of the old global `.nas-sync-state/sync-manifest.txt`.
5. **Decommission the old global manifest** — once the client logs the per-client path,
   delete the stale `.nas-sync-state/sync-manifest.txt` and `last-sync-marker` on the
   source NAS (the v3.14 model is stateless and no longer uses a marker).
6. **Add further targets** per §9A.3.

> No data re-sync is required for the existing target: its files already match. The first
> v3.14 incremental run simply pulls whatever changed within `nas-a`'s lookback window.
```

- [ ] **Step 7: Verify all edits landed and no old single-target names remain in the checklist**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
F=cross-cluster-rsync-guide-v3.14-consolidated.md
grep -n 'cronjob-manifest\.yaml\|generate-manifest\.sh' "$F" || echo "no stale single-target filenames"
grep -c 'Status in v3.14' "$F"
grep -c '## Appendix: Migrating' "$F"
grep -c 'Multi-target: per-client manifests' "$F"
```
Expected: `no stale single-target filenames`; `Status in v3.14` = 1; appendix = 1; multi-target row = 1.

- [ ] **Step 8: Commit**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
v3.14: intro, file checklist, consolidates table, migration appendix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Whole-document consistency sweep

Final gate: prove every embedded script is LF-only, every YAML block parses, cross-references resolve, and no placeholders slipped in.

**Files:**
- Modify (only if the sweep finds issues): `cross-cluster-rsync-guide-v3.14-consolidated.md`

- [ ] **Step 1: CRLF guard — no carriage returns anywhere**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -n $'\r' cross-cluster-rsync-guide-v3.14-consolidated.md && echo "CRLF FOUND — FIX" || echo "LF clean"
```
Expected: `LF clean`. If CRLF found, run `sed -i 's/\r$//' cross-cluster-rsync-guide-v3.14-consolidated.md` and re-check.

- [ ] **Step 2: Every shell fence shebang is clean `#!/bin/bash`**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -n '#!/bin/bash' cross-cluster-rsync-guide-v3.14-consolidated.md | head
grep -n '#!/bin/bash\r' cross-cluster-rsync-guide-v3.14-consolidated.md && echo "SHEBANG CRLF — FIX" || echo "shebangs clean"
```
Expected: shebangs listed; `shebangs clean`.

- [ ] **Step 3: Every YAML fence parses** (if python3+pyyaml available)

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
command -v python3 >/dev/null 2>&1 && python3 - cross-cluster-rsync-guide-v3.14-consolidated.md <<'PY' || echo "python3/pyyaml unavailable — skip (visually verify YAML blocks)"
import re,sys,yaml
t=open(sys.argv[1],encoding="utf-8").read()
blocks=re.findall(r"```yaml\n(.*?)\n```",t,re.S)
bad=0
for i,b in enumerate(blocks):
    try: list(yaml.safe_load_all(b))
    except Exception as e: bad+=1; print(f"YAML block {i} FAILED: {e}")
print(f"checked {len(blocks)} yaml blocks, {bad} failed")
PY
```
Expected: `... 0 failed` (or the skip message). Fix any reported block.

- [ ] **Step 4: Cross-reference + filename consistency**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
F=cross-cluster-rsync-guide-v3.14-consolidated.md
echo "--- stale single-target filenames (expect none):"
grep -n 'generate-manifest\.sh\|cronjob-manifest\.yaml' "$F" || echo "  none"
echo "--- new section anchors (expect 6.2 and 9A.3 present):"
grep -nc '### 6.2\|### 9A.3' "$F"
echo "--- referenced sections exist:"
for s in '### 4.3' '### 6.1' '### 6.2' '### 8.4' '### 9A.2' '### 9A.3' '## Appendix: Migrating'; do
  grep -q "$s" "$F" && echo "  OK $s" || echo "  MISSING $s"; done
```
Expected: no stale filenames; the 6.2/9A.3 count = 2; all referenced sections `OK`.

- [ ] **Step 5: Placeholder scan (plan-failure patterns)**

Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
grep -nE 'TBD|TODO|FIXME|fill in|implement later' cross-cluster-rsync-guide-v3.14-consolidated.md || echo "no placeholders"
echo "--- intended placeholders that MUST remain:"
grep -c 'your-registry.example.com\|ISTIO_EXTERNAL_IP_HERE\|◄ MODIFY' cross-cluster-rsync-guide-v3.14-consolidated.md
```
Expected: `no placeholders`; the intended-placeholder count > 0 (those are deliberate `◄ MODIFY` markers).

- [ ] **Step 6: Final functional re-test of the generator (regression)**

Re-run the Task 2 generator test against the script AS EMBEDDED in the guide, to prove the committed text still works. Run:
```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
SBX="$(mktemp -d)"
python3 - cross-cluster-rsync-guide-v3.14-consolidated.md "$SBX/generate-manifests.sh" <<'PY' 2>/dev/null || \
  awk '/### 4.3/{f=1} f&&/^```bash$/{c++; if(c==1){g=1; next}} g&&/^```$/{g=0} g{print}' cross-cluster-rsync-guide-v3.14-consolidated.md > "$SBX/generate-manifests.sh"
import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
seg=t.split('### 4.3',1)[1]
body=re.search(r"```bash\n(.*?)\n```",seg,re.S).group(1)
open(sys.argv[2],"w",encoding="utf-8",newline="\n").write(body+"\n")
PY
# reuse the Task 2 harness inline:
SRC="$SBX/src"; mkdir -p "$SRC/sub" "$SRC/.snapshot" "$SRC/.nas-sync-state/clients"
echo x > "$SRC/recent.txt";  touch -d '1 hour ago'    "$SRC/recent.txt"
echo x > "$SRC/sub/mid.txt"; touch -d '10 hours ago'  "$SRC/sub/mid.txt"
echo x > "$SRC/old.txt";     touch -d '100 hours ago' "$SRC/old.txt"
printf 'fast 6\nslow 48\n' > "$SBX/clients.txt"
SOURCE_PATH="$SRC" STATE_DIR="$SRC/.nas-sync-state" REGISTRY_FILE="$SBX/clients.txt" bash "$SBX/generate-manifests.sh"
FAST="$SRC/.nas-sync-state/clients/fast/sync-manifest.txt"; SLOW="$SRC/.nas-sync-state/clients/slow/sync-manifest.txt"
grep -qx 'recent.txt' "$FAST" && ! grep -qx 'sub/mid.txt' "$FAST" && grep -qx 'sub/mid.txt' "$SLOW" && echo "EMBEDDED SCRIPT PASS" || echo "EMBEDDED SCRIPT FAIL"
rm -rf "$SBX"
```
Expected: `EMBEDDED SCRIPT PASS`. (If python3 is unavailable the `awk` fallback extracts the block; if both struggle, manually copy the §4.3 block to a file and run the Task 2 harness.)

- [ ] **Step 7: Commit (only if Steps 1–4 required fixes; otherwise skip)**

```bash
cd "C:/Users/leo01/OneDrive/桌面/dev/nassync"
git add cross-cluster-rsync-guide-v3.14-consolidated.md
git commit -m "$(cat <<'EOF'
v3.14: consistency sweep fixes (CRLF/YAML/cross-refs)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage** (each spec section → task):
- §4 D1 stateless lookback → Task 2 (generator), §6.2 explainer Task 3.
- §4 D2 single-walk fan-out → Task 2.
- §4 D3 registry ConfigMap → Task 3.
- §4 D4 bootstrap-via-parallel → Task 5 (§9A.3 step 3).
- §4 D5 weekly reconcile retained → Task 5 (§9A.3 step 5).
- §4 D6 new consolidated guide → Task 1 + all.
- §6.1 state layout → Task 2 (paths) + Task 6 (verify).
- §6.2 registry format → Task 3.
- §6.3 generator algorithm → Task 2.
- §6.4 client CLIENT_ID → Task 4.
- §6.5 generator CronJob → Task 3.
- §7 data flow → covered across generator (T2) + client (T4) + walkthrough (T5).
- §8 window sizing → Task 3 §6.2 text + Task 5 §9A.3.
- §9 failure modes → Task 4 (fallback/skip) + Task 6 (troubleshooting).
- §10 preserved invariants → Global Constraints + Task 8 CRLF/read-only checks.
- §11 deliverable structure → Tasks 1–7; §14/consolidates/appendix in Task 7.
- §12 open questions → none; registry placeholders shipped (Task 3).

**Placeholder scan:** No TBD/TODO/"handle edge cases" in steps; every code/edit step shows exact content. Intended `◄ MODIFY` / `your-registry.example.com` / `ISTIO_EXTERNAL_IP_HERE` markers are explicitly preserved and checked in Task 8 Step 5.

**Type/name consistency:** `generate-manifests.sh`, `nas-sync-clients` (registry CM), `clients.txt`, `/userapp/config/clients.txt`, `REGISTRY_FILE`, `CLIENT_ID`, and `.nas-sync-state/clients/<CLIENT_ID>/sync-manifest.txt` are used identically across Tasks 2–8. The client derivation (Task 4) targets the same path the generator writes (Task 2). Image tag `:3.14` consistent (Task 1 + Task 3 YAML).
