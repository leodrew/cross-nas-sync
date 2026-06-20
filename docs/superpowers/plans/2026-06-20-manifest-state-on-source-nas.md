# Manifest State on Source NAS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move incremental-mode sync-state off the Kubernetes PVC and onto the source NAS (`${SOURCE_PATH}/.nas-sync-state/`), delete the PVC, and keep the guide internally consistent.

**Architecture:** Edit the single authoritative guide `cross-cluster-rsync-guide-v3.13-consolidated.md`. Producer (Cluster B) writes the marker + manifest into a hidden dir on the source NAS; consumer (Cluster A) fetches the manifest from that dir; bulk syncs exclude the dir client-side; the PVC and its volume/mount are removed.

**Tech Stack:** Markdown guide containing fenced Bash scripts, Dockerfiles, and Kubernetes/Istio YAML. No build system. "Tests" are `grep`/CRLF/consistency checks against the edited file.

## Global Constraints

- **Single file under edit:** `cross-cluster-rsync-guide-v3.13-consolidated.md` (repo root). Referred to below as **the guide**.
- **LF only.** Never introduce CRLF. Every task's final check includes `grep -c $'\r' <guide>` must print `0`.
- **Copy-paste-ready.** All fenced scripts/YAML must stay valid; keep placeholders (`your-registry.example.com`, `10.90.220.155`, `◄ MODIFY`) intact unless a step changes them.
- **Producer/consumer manifest-path contract (exact string):** the manifest lives at `${SOURCE_PATH}/.nas-sync-state/sync-manifest.txt` on the NAS; the consumer fetches it via the rsync-relative path **`.nas-sync-state/sync-manifest.txt`**. These two MUST match.
- **State dir (exact string):** `${SOURCE_PATH}/.nas-sync-state` → resolves to `/mnt/nas-source/.nas-sync-state` in-pod.
- **Exclude comments rule:** `rsync --exclude-from` does NOT treat `#` lines as comments (the file already uses `#recycle/` as a literal pattern). Put explanations for the exclude in **markdown prose only**, never inside the `rsync-exclude.txt` literal block. `rsyncd.conf` (§5.2) DOES support `#` comments.
- **No git:** this directory is not a git repository. "Commit" below is optional — only run it if the user has run `git init`. Otherwise the per-task verification grep is the gate.
- **Section renumber:** deleting `§6.1` (the PVC) means the manifest CronJob becomes `§6.1`. Keep `§14` and the "What This Consolidates" table in sync.

---

### Task 1: Producer — state on the NAS (`§4.3` script + `§4.4` Dockerfile)

**Files:**
- Modify: the guide, `§4.3 generate-manifest.sh` fenced block (around lines 185–218)
- Modify: the guide, `§4.4 Dockerfile` fenced block (around line 241)

**Interfaces:**
- Produces: state dir `${SOURCE_PATH}/.nas-sync-state`; manifest at `${SOURCE_PATH}/.nas-sync-state/sync-manifest.txt`; marker at `${SOURCE_PATH}/.nas-sync-state/last-sync-marker`. (Consumed by Task 4's `MANIFEST_NAME` and Task 2's `STATE_DIR` env.)

- [ ] **Step 1: Repoint the script's state variables onto the NAS**

Replace this exact block:

```bash
SOURCE_PATH="${SOURCE_PATH:-/mnt/nas-source}"
STATE_DIR="${STATE_DIR:-/state}"
MARKER="${STATE_DIR}/last-sync-marker"
MARKER_CANDIDATE="${STATE_DIR}/last-sync-marker.candidate"
MANIFEST="${MANIFEST_PATH:-${SOURCE_PATH}/.sync-manifest.txt}"
```

with:

```bash
SOURCE_PATH="${SOURCE_PATH:-/mnt/nas-source}"
# State dir now lives ON the source NAS (no Kubernetes PVC): survives pod
# rescheduling and adds no new storage dependency (the NAS is already required).
STATE_DIR="${STATE_DIR:-${SOURCE_PATH}/.nas-sync-state}"
MARKER="${STATE_DIR}/last-sync-marker"
MARKER_CANDIDATE="${STATE_DIR}/last-sync-marker.candidate"
MANIFEST="${MANIFEST_PATH:-${STATE_DIR}/sync-manifest.txt}"
```

- [ ] **Step 2: Add orphan-candidate cleanup after the mkdir**

Replace this exact block:

```bash
mkdir -p "$STATE_DIR"

log "========================================"
log "Manifest Generator v3.13"
log "  Source: $SOURCE_PATH | Marker: $MARKER"
log "========================================"
```

with:

```bash
mkdir -p "$STATE_DIR"

# Hygiene: drop any orphan candidate left by a crashed previous run.
# Safe because the CronJob uses concurrencyPolicy: Forbid (no concurrent run).
rm -f "$MARKER_CANDIDATE"

log "========================================"
log "Manifest Generator v3.13"
log "  Source: $SOURCE_PATH | State: $STATE_DIR"
log "========================================"
```

- [ ] **Step 3: Prune the whole state dir in the `find`**

Replace this exact line:

```bash
        -path "$MANIFEST" -prune -o \
```

with:

```bash
        -path "$STATE_DIR" -prune -o \
```

- [ ] **Step 4: Drop the dead `/state` mkdir from the server Dockerfile (`§4.4`)**

Replace this exact line:

```dockerfile
RUN mkdir -p /mnt/nas-source /state
```

with:

```dockerfile
RUN mkdir -p /mnt/nas-source
```

- [ ] **Step 5: Verify the producer edits**

Run (from repo root):

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n 'STATE_DIR:-${SOURCE_PATH}/.nas-sync-state' "$g"   # state default on NAS
grep -n 'MANIFEST_PATH:-${STATE_DIR}/sync-manifest.txt' "$g" # manifest in state dir
grep -n 'rm -f "\$MARKER_CANDIDATE"' "$g"                   # orphan cleanup present
grep -n '\-path "\$STATE_DIR" -prune' "$g"                  # prune whole state dir
grep -n 'mkdir -p /mnt/nas-source$' "$g"                    # Dockerfile no longer makes /state
grep -c 'mkdir -p /mnt/nas-source /state' "$g"               # expect 0 (Dockerfile /state removed)
grep -c $'\r' "$g"                                           # expect 0 (LF only)
```

Expected: lines 1–5 each return exactly one match; the Dockerfile `/state` count is `0`; the CRLF count is `0`.

> **Gate correction (post-mortem):** an earlier version of this step used `grep -c '/state' == 0`
> across the whole file. That is unsatisfiable at the end of Task 1 alone — the §6.2 CronJob
> still legitimately contains `/state` (its `STATE_DIR` env + `mountPath`) until Task 2. The
> check is scoped to the Dockerfile line above; the CronJob's `/state` is verified in Task 2.
> Run `grep -c $'\r'` as a STANDALONE command — nesting `$'\r'` inside `echo "$(...)"` mis-parses
> and reports a false positive equal to the line count.

- [ ] **Step 6 (optional): Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: store manifest state on source NAS (producer script + Dockerfile)"
```

---

### Task 2: Producer CronJob — drop the PVC volume (`§6.2`)

**Files:**
- Modify: the guide, `§6.2 cronjob-manifest.yaml` fenced block (env around 571–580, volumes around 582–590)

**Interfaces:**
- Consumes: `STATE_DIR` default from Task 1 (sets it explicitly to `/mnt/nas-source/.nas-sync-state`).
- Produces: a manifest CronJob with a single `nas-source` NFS volume and no PVC.

- [ ] **Step 1: Replace the env + volumeMounts (remove the `state` mount, pin `STATE_DIR`)**

Replace this exact block:

```yaml
              env:
                - name: SOURCE_PATH
                  value: "/mnt/nas-source"
                - name: STATE_DIR
                  value: "/state"
              volumeMounts:
                - name: nas-source
                  mountPath: /mnt/nas-source
                - name: state
                  mountPath: /state
```

with:

```yaml
              env:
                - name: SOURCE_PATH
                  value: "/mnt/nas-source"
                # State now lives on the source NAS (no PVC). The script default is
                # ${SOURCE_PATH}/.nas-sync-state; set explicitly here for clarity:
                - name: STATE_DIR
                  value: "/mnt/nas-source/.nas-sync-state"
              volumeMounts:
                - name: nas-source
                  mountPath: /mnt/nas-source
```

- [ ] **Step 2: Replace the volumes (remove the PVC volume, note the rw requirement)**

Replace this exact block:

```yaml
          volumes:
            - name: nas-source
              nfs:
                server: "10.90.220.155"          # ◄ MODIFY
                path: "/PMCenterData"            # ◄ MODIFY
                readOnly: false
            - name: state
              persistentVolumeClaim:
                claimName: manifest-state-pvc
```

with:

```yaml
          volumes:
            - name: nas-source
              nfs:
                server: "10.90.220.155"          # ◄ MODIFY
                path: "/PMCenterData"            # ◄ MODIFY
                readOnly: false                  # REQUIRED: manifest + state are written here
```

- [ ] **Step 3: Verify**

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n 'value: "/mnt/nas-source/.nas-sync-state"' "$g"   # STATE_DIR pinned to NAS
grep -c 'mountPath: /state' "$g"                          # expect 0
grep -c 'claimName: manifest-state-pvc' "$g"              # expect 0 (PVC volume gone)
grep -n 'REQUIRED: manifest + state are written here' "$g"
grep -c $'\r' "$g"                                         # expect 0
```

Expected: the two `grep -n` lines return one match each; both `grep -c` for `/state` mount and the claimName return `0`; CRLF count `0`.

- [ ] **Step 4 (optional): Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: remove manifest-state PVC volume from manifest CronJob"
```

---

### Task 3: Delete the PVC section and renumber `§6` (`§6.1`, apply block)

**Files:**
- Modify: the guide, `§6.1 manifest-state-pvc.yaml` (delete, around 516–540), `§6.2` heading (renumber, ~542), apply block (~593–597)

**Interfaces:**
- Produces: `§6` containing exactly one sub-section, `§6.1 cronjob-manifest.yaml`. (Consumed by Task 5's `§14` + table edits.)

- [ ] **Step 1: Delete the entire `§6.1 manifest-state-pvc.yaml` block**

Remove this exact block (heading, fenced YAML, and the trailing blank line before `### 6.2`):

````markdown
### 6.1 manifest-state-pvc.yaml

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: manifest-state-pvc
  namespace: ea-pmc
spec:
  accessModes: [ReadWriteOnce]
  # This PVC is small *persistent scratch space on Cluster B* — it stores ONLY the
  # `last-sync-marker` timestamp file used by `find -newer` (see §4.3). It is NOT on
  # NAS A or NAS B; it is provisioned dynamically by a StorageClass on Cluster B.
  storageClassName: standard       # ◄ MODIFY — a StorageClass that exists on Cluster B.
                                   #   Find yours with:  kubectl get storageclass
                                   #   Common names: standard | local-path | managed-nfs
                                   #                  gp2 | gp3 | csi-...  (cloud/CSI driver)
                                   #   If Cluster B has a DEFAULT StorageClass, DELETE this
                                   #   line to use it. If you omit it AND there is no default
                                   #   SC, the PVC stays Pending forever and the manifest
                                   #   CronJob never starts.
  resources:
    requests:
      storage: 1Gi                 # only a few KB are actually used (one marker file)
```

````

(After deletion, `### 6.2 cronjob-manifest.yaml` should directly follow the `§6` intro `> Only needed if you use incremental mode.` line, separated by one blank line.)

- [ ] **Step 2: Renumber the CronJob sub-section to `§6.1`**

Replace this exact line:

```markdown
### 6.2 cronjob-manifest.yaml
```

with:

```markdown
### 6.1 cronjob-manifest.yaml
```

- [ ] **Step 3: Remove the PVC apply line**

Replace this exact block:

```bash
# Only if using incremental mode:
kubectl apply -f cluster-b/manifest-state-pvc.yaml
kubectl apply -f cluster-b/cronjob-manifest.yaml
```

with:

```bash
# Only if using incremental mode:
kubectl apply -f cluster-b/cronjob-manifest.yaml
```

- [ ] **Step 4: Verify**

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n 'manifest-state-pvc' "$g"          # expect EXACTLY ONE: the §14 checklist line (removed in Task 5)
grep -c '### 6.2 ' "$g"                     # expect 0 (renumbered)
grep -n '### 6.1 cronjob-manifest.yaml' "$g"
grep -c 'storageClassName: standard' "$g"   # expect 0 (the earlier fix is gone with the block)
grep -c $'\r' "$g"                          # expect 0
```

Expected: `manifest-state-pvc` returns EXACTLY ONE line — the §14 checklist entry (cleaned up in Task 5; do NOT edit §14 here); `### 6.2 ` count `0`; the `### 6.1 cronjob-manifest.yaml` line found; `storageClassName: standard` count `0`; CRLF `0`.

> **Gate correction (post-mortem):** this step originally used `grep -c 'manifest-state-pvc' == 0`,
> unsatisfiable at the end of Task 3 alone — the §14 checklist still lists `manifest-state-pvc.yaml`
> until Task 5. Scoped to expect the one remaining §14 reference so Task 3 does not bleed into §14.

- [ ] **Step 5 (optional): Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: delete manifest-state PVC section, renumber 6.2 -> 6.1"
```

---

### Task 4: Consumer + exclusion (`§8.4`, `§9A.1`, `§5.2`)

**Files:**
- Modify: the guide, `§8.4 nas-sync-incremental.sh` (`MANIFEST_NAME`, ~line 762)
- Modify: the guide, `§9A.1 configmap-exclude.yaml` literal block (add pattern) + a markdown note after the block
- Modify: the guide, `§5.2 configmap-rsyncd.yaml` rsyncd.conf block (guard comment above `exclude =`)

**Interfaces:**
- Consumes: manifest path contract from Task 1 → fetch path `.nas-sync-state/sync-manifest.txt`.

- [ ] **Step 1: Repoint the consumer's manifest fetch path**

Replace this exact line:

```bash
MANIFEST_NAME="${MANIFEST_NAME:-.sync-manifest.txt}"
```

with:

```bash
MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"
```

- [ ] **Step 2: Add the exclude PATTERN ONLY (no inline comment) to `rsync-exclude.txt`**

Replace this exact block:

```yaml
    .DS_Store
    Thumbs.db
    .git/
```

with:

```yaml
    .DS_Store
    Thumbs.db
    .git/
    .nas-sync-state/
```

> Note: do NOT add `#` comment lines inside this block — `rsync --exclude-from` treats `#`-lines as literal patterns (this file already relies on that for `#recycle/`). The explanation goes in markdown prose in Step 3.

- [ ] **Step 3: Add a markdown guard note after the `§9A.1` YAML block**

Find this exact boundary (end of the `§9A.1` combined YAML, start of `§9A.2`):

````markdown
  rsync.password: "YourSecurePassword123!"
```

### 9A.2 File: `cluster-a/cronjob-client.yaml`
````

Replace it with:

````markdown
  rsync.password: "YourSecurePassword123!"
```

> **`.nas-sync-state/` is client-side only.** It excludes the source NAS sync-state
> (manifest + marker) from being copied to NAS A by `standard`/`parallel`/full syncs.
> Incremental mode still fetches the manifest from it explicitly (that fetch does not
> use `--exclude-from`), so this MUST stay out of the rsyncd server `exclude =` (§5.2),
> or the manifest fetch fails and incremental silently degrades to a full sync.

### 9A.2 File: `cluster-a/cronjob-client.yaml`
````

- [ ] **Step 4: Add the server-side guard comment in `§5.2` (rsyncd.conf supports `#`)**

Replace this exact line:

```
        exclude = .snapshot/ .snapshots/ .zfs/ @Recently-Snapshot/ @Recycle/ #recycle/ @eaDir/ @tmp/
```

with:

```
        # Do NOT add .nas-sync-state/ here — the client fetches the manifest from it.
        # Target-side exclusion is handled CLIENT-side in rsync-exclude.txt (§9A.1).
        exclude = .snapshot/ .snapshots/ .zfs/ @Recently-Snapshot/ @Recycle/ #recycle/ @eaDir/ @tmp/
```

- [ ] **Step 5: Verify**

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n 'MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt' "$g"  # consumer path updated
grep -n '^    .nas-sync-state/$' "$g"                            # exclude pattern present (4-space indent)
grep -n 'client-side only' "$g"                                  # markdown guard note present
grep -n 'Do NOT add .nas-sync-state/ here' "$g"                  # server guard comment present
grep -c $'\r' "$g"                                                # expect 0
```

Expected: each `grep -n` returns at least one match; CRLF count `0`. Confirm the consumer fetch path string equals the producer manifest path tail `.nas-sync-state/sync-manifest.txt` (Global Constraints contract).

- [ ] **Step 6 (optional): Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: fetch manifest from NAS state dir, exclude it client-side with guards"
```

---

### Task 5: Doc consistency (`§13`, `§14`, consolidates table)

**Files:**
- Modify: the guide, `§13` troubleshoot command (~line 1482), `§14` Cluster B checklist (~1510–1511), "What This Consolidates" table (~1576)

**Interfaces:**
- Consumes: Task 3's renumber (`§6` now has only `6.1`) and Task 1/2/4 paths.

- [ ] **Step 1: Fix the troubleshooting `ls` path (`§13`)**

Replace this exact block:

```bash
# Check manifest job ran and wrote the file
kubectl logs job/<manifest-job> -n ea-pmc
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.sync-manifest.txt
```

with:

```bash
# Check manifest job ran and wrote the file
kubectl logs job/<manifest-job> -n ea-pmc
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.nas-sync-state/
```

- [ ] **Step 2: Update the `§14` Cluster B checklist**

Replace this exact block:

```
├── manifest-state-pvc.yaml         # 6.1  (incremental only — MODIFY storageClassName)
├── cronjob-manifest.yaml           # 6.2  (incremental only)
```

with:

```
├── cronjob-manifest.yaml           # 6.1  (incremental only)
```

- [ ] **Step 3: Replace the consolidates-table row**

Replace this exact line:

```
| Explicit target NFS PV+PVC + manifest StorageClass | (this request) | ✓ (9A.1, 6.1) |
```

with:

```
| Explicit target NFS PV+PVC | (this request) | ✓ (9A.1) |
| Manifest state on source NAS (no PVC) | (this request) | ✓ (§6) |
```

- [ ] **Step 4: Verify**

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
grep -c 'manifest-state-pvc' "$g"                       # expect 0 (gone from checklist too)
grep -c 'MODIFY storageClassName' "$g"                  # expect 0
grep -n 'ls -la /mnt/nas-source/.nas-sync-state/' "$g"  # troubleshoot path updated
grep -n 'Manifest state on source NAS' "$g"             # table row added
grep -c '# 6.2' "$g"                                    # expect 0 (no stale 6.2 refs)
grep -c $'\r' "$g"                                       # expect 0
```

Expected: `manifest-state-pvc` and `MODIFY storageClassName` and `# 6.2` counts are `0`; the two `grep -n` lines match; CRLF `0`.

- [ ] **Step 5 (optional): Commit**

```bash
git add cross-cluster-rsync-guide-v3.13-consolidated.md
git commit -m "docs: reconcile checklist, troubleshooting path, and consolidates table"
```

---

### Task 6: Whole-guide consistency pass (final gate)

**Files:**
- Read-only verification of the guide (no edits unless a check fails).

- [ ] **Step 1: Run the full consistency sweep**

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
echo "== must be 0 =="
grep -c $'\r' "$g"                                  # CRLF
grep -c 'manifest-state-pvc' "$g"                   # PVC fully gone
grep -c 'mountPath: /state' "$g"                    # no PVC mount
grep -Ec '(^|[^.])/state\b' "$g"                    # no bare /state references
grep -c '### 6.2 ' "$g"                             # renumber complete
grep -c '${SOURCE_PATH}/.sync-manifest.txt' "$g"    # old manifest path gone
echo "== must be >=1 =="
grep -c '.nas-sync-state' "$g"                       # new state dir referenced
grep -c '### 6.1 cronjob-manifest.yaml' "$g"         # cronjob renumbered
```

Expected: every count in the "must be 0" group is `0`; every count in the "must be >=1" group is `>=1`.

- [ ] **Step 2: Confirm the producer/consumer path contract matches**

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n 'sync-manifest.txt' "$g"
```

Expected output contains exactly these intentional occurrences (and no stray root-level `.sync-manifest.txt`):
- producer: `MANIFEST="${MANIFEST_PATH:-${STATE_DIR}/sync-manifest.txt}"`
- consumer remote path: `MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"`
- consumer local temp (unchanged, fine): `MANIFEST_LOCAL="/tmp/sync-manifest.txt"`

- [ ] **Step 3: Spot-check the `find` prune did not orphan `.snapshot`**

```bash
g=cross-cluster-rsync-guide-v3.13-consolidated.md
grep -n 'path "\$SOURCE_PATH/.snapshot" -prune' "$g"   # snapshot prune still present
grep -n 'path "\$STATE_DIR" -prune' "$g"               # state prune present
```

Expected: both lines present (the `find` prunes both the snapshot dir and the state dir).

- [ ] **Step 4 (optional): Commit / report**

If git is initialized: confirm a clean tree (`git status`). Otherwise report the sweep output to the user as the completion gate.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Spec §4.1 producer script → Task 1 ✓
- Spec §4.2 producer CronJob → Task 2 ✓
- Spec §4.3 consumer script → Task 4 Step 1 ✓
- Spec §4.4 client exclude → Task 4 Steps 2–3 ✓
- Spec §4.5 server guard comment → Task 4 Step 4 ✓
- Spec §4.6 remove PVC + renumber → Task 3 + Task 5 Step 2 ✓
- Spec §4.7 doc consistency (table, prose, sweep) → Task 5 + Task 6 ✓
- Spec §5 purge/hygiene (self-clean in producer) → Task 1 Step 2 ✓
- Spec §10 verification → Tasks’ verify steps + Task 6 ✓
- **Added beyond spec (gaps found during planning):** server Dockerfile `/state` removal (Task 1 Step 4) and `§13` troubleshoot path (Task 5 Step 1). Both are doc-consistency fixes the spec’s "grep for references" clause implies.
- **Not in scope (per spec §2 non-goals):** migration/cutover one-time full sync (operational, spec §6), version bump (spec §9), separate purge CronJob.

**Placeholder scan:** none — every step has the exact before/after text and exact verify commands.

**Type/string consistency:** producer manifest `${STATE_DIR}/sync-manifest.txt` (= `/mnt/nas-source/.nas-sync-state/sync-manifest.txt`) matches consumer fetch `.nas-sync-state/sync-manifest.txt`; `STATE_DIR` default `${SOURCE_PATH}/.nas-sync-state` matches the CronJob’s explicit `/mnt/nas-source/.nas-sync-state`; renumber `6.2 → 6.1` is reflected in `§14` and verified in Task 6.
