# Design: Move manifest sync-state to the source NAS (drop the K8s PVC)

- **Date:** 2026-06-20
- **Status:** Approved (ready for implementation plan)
- **Target doc:** `cross-cluster-rsync-guide-v3.13-consolidated.md`
- **Scope:** Incremental-mode manifest **state storage** only. No change to standard/parallel modes, the reconcile strategy, or the NAS A target storage (handled separately).

---

## 1. Background

Incremental mode uses a server-generated manifest of changed files:

- **Producer** — `generate-manifest.sh` (Cluster B, `nas-sync-manifest` CronJob, `§4.3` / `§6.2`).
  Runs `find -newer <marker>` against the source NAS and writes the changed-file list.
- **Consumer** — `nas-sync-incremental.sh` (Cluster A, `§8.4`).
  Fetches the manifest via rsync and passes it to `rsync --files-from`.

Today the state is split across two locations:

| Artifact | Lives on (today) | Role | Must persist? |
|----------|------------------|------|---------------|
| `last-sync-marker` | **K8s PVC** `manifest-state-pvc` (`§6.1`) | mtime reference for `find -newer` | **Yes** — losing it forces a full resync |
| `last-sync-marker.candidate` | K8s PVC | transient; renamed to the marker on success | No |
| `.sync-manifest.txt` | **source NAS root** (`${SOURCE_PATH}/.sync-manifest.txt`) | changed-file list, overwritten each run | No (regenerated) |

### Problem
The only must-persist artifact (the marker) sits on a PVC backed by the cluster's default `StorageClass`, which the operator does not consider reliable:

- A `local-path`-style provisioner pins the volume to one node; pod rescheduling loses the marker → unintended full resync of ~7.4M folders.
- If Cluster B has no default `StorageClass`, the PVC stays `Pending` and the manifest CronJob never starts.
- It is an extra storage dependency layered on top of a system that *already* hard-depends on the source NAS.

### Latent bug found during design
`.sync-manifest.txt` sits at the rsync module root and is **not** in any exclude list, so a `standard` / `parallel` / FULL sync currently copies it onto NAS A. This design fixes that.

---

## 2. Goals / Non-goals

**Goals**
1. Store the persistent marker on storage the operator trusts, with no new dependency.
2. Remove the K8s `StorageClass` from the critical path.
3. Make the "no buildup / hygiene" property structural and explicit.
4. Stop sync-tooling artifacts from propagating to NAS A.

**Non-goals**
- Changing reconcile behavior. The weekly **parallel** CronJob remains the full-reconcile path; incremental stays purely incremental.
- Forcing periodic full syncs by resetting the marker (explicitly rejected — too slow at scale).
- Keeping manifest history / audit trail (not wanted).
- Bumping the guide version or renaming the file (editorial, out of scope — see §9).
- NAS A target PV/PVC (separate change, already applied).

---

## 3. Chosen approach — Approach A: all state on the source NAS

Move every sync-state artifact into a single hidden directory on the source NAS and delete the PVC.

```
${SOURCE_PATH}/.nas-sync-state/        # e.g. /mnt/nas-source/.nas-sync-state/
├── last-sync-marker                   # persistent find -newer reference (the only must-survive file)
├── last-sync-marker.candidate         # transient; mv-renamed to the marker on success
└── sync-manifest.txt                  # changed-file list; overwritten each run (first run: FULL_SYNC)
```

**Why this is safe / better**
- The source NAS is already a hard dependency (the manifest CronJob mounts it `rw`; the rsync daemon serves it). No new failure mode is introduced.
- Marker survives pod rescheduling (a node-local PVC does not).
- One directory → one exclude rule, structurally bounded to ~3 small files, trivially reasoned about.
- Removes a PVC, a volume, a volume mount, and the `StorageClass` question.

**Cost accepted:** writes a hidden dir into the production source NAS — already accepted today for `.sync-manifest.txt`.

**Clock semantics:** unchanged. `find -newer` still compares mtimes and still assumes NTP-synced clocks, exactly as with the PVC.

---

## 4. Detailed changes

### 4.1 Producer script — `§4.3 generate-manifest.sh`

Defaults move onto the NAS, the `find` prunes the whole state dir, and an orphan-candidate cleanup is added.

```bash
#!/bin/bash
#############################################
# Manifest Generator (Cluster B)
# Lists files changed since last sync for
# incremental mode (--files-from on client).
# State lives on the source NAS (no PVC).
#############################################
set +e

SOURCE_PATH="${SOURCE_PATH:-/mnt/nas-source}"
# State dir now lives ON the source NAS (no Kubernetes PVC): survives pod
# rescheduling and adds no new storage dependency (the NAS is already required).
STATE_DIR="${STATE_DIR:-${SOURCE_PATH}/.nas-sync-state}"
MARKER="${STATE_DIR}/last-sync-marker"
MARKER_CANDIDATE="${STATE_DIR}/last-sync-marker.candidate"
MANIFEST="${MANIFEST_PATH:-${STATE_DIR}/sync-manifest.txt}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

mkdir -p "$STATE_DIR"

# Hygiene: drop any orphan candidate left by a crashed previous run.
# Safe because the CronJob uses concurrencyPolicy: Forbid (no concurrent run).
rm -f "$MARKER_CANDIDATE"

log "========================================"
log "Manifest Generator"
log "  Source: $SOURCE_PATH | State: $STATE_DIR"
log "========================================"

# Capture scan start time; files changed during scan caught next run
touch "$MARKER_CANDIDATE"

if [ ! -f "$MARKER" ]; then
    log "No marker — first run. Signaling FULL_SYNC."
    echo "FULL_SYNC" > "$MANIFEST"
else
    log "Generating changed-file list (newer than marker)..."
    # Prune the ENTIRE state dir so the marker/manifest never self-report as changed.
    find "$SOURCE_PATH" \
        -path "$SOURCE_PATH/.snapshot" -prune -o \
        -path "$STATE_DIR" -prune -o \
        -type f -newer "$MARKER" -printf '%P\n' \
        > "$MANIFEST" 2>/dev/null
    CHANGED=$(wc -l < "$MANIFEST")
    log "Found $CHANGED changed files"
fi

mv "$MARKER_CANDIDATE" "$MARKER"
log "Manifest written to $MANIFEST. Done."
```

Changes vs current: `STATE_DIR` default → `${SOURCE_PATH}/.nas-sync-state`; `MANIFEST` default → `${STATE_DIR}/sync-manifest.txt`; `find` prunes `$STATE_DIR` (was the single `$MANIFEST` file); added `rm -f "$MARKER_CANDIDATE"` orphan cleanup. The atomic `touch`→`find`→`mv` sequence is preserved.

### 4.2 Producer manifest — `§6.2 cronjob-manifest.yaml`

Remove the PVC volume + mount; pin `STATE_DIR` for clarity; keep the source NFS mount `rw`.

```yaml
              env:
                - name: SOURCE_PATH
                  value: "/mnt/nas-source"
                # State now lives on the source NAS (no PVC). Default is
                # ${SOURCE_PATH}/.nas-sync-state; set explicitly for clarity:
                - name: STATE_DIR
                  value: "/mnt/nas-source/.nas-sync-state"
              volumeMounts:
                - name: nas-source
                  mountPath: /mnt/nas-source
          restartPolicy: Never
          volumes:
            - name: nas-source
              nfs:
                server: "10.90.220.155"          # ◄ MODIFY
                path: "/PMCenterData"            # ◄ MODIFY
                readOnly: false                  # REQUIRED: manifest + state are written here
```

Removed: the `- name: state … persistentVolumeClaim: claimName: manifest-state-pvc` volume, the `- name: state mountPath: /state` mount, and the `STATE_DIR=/state` value.

### 4.3 Consumer script — `§8.4 nas-sync-incremental.sh`

One-line default change:

```bash
# was: MANIFEST_NAME="${MANIFEST_NAME:-.sync-manifest.txt}"
MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"
```

No other change. The explicit fetch (`rsync -a --password-file=… "${REMOTE_URL}/${MANIFEST_NAME}" "$MANIFEST_LOCAL"`) runs **without** `--exclude-from`, so it still succeeds even though bulk syncs exclude the dir (see §4.5). The `FULL_SYNC` check and `--files-from` usage are unaffected.

### 4.4 Client exclude — `§9A.1 configmap-exclude.yaml` (`rsync-exclude.txt`)

Add, with a guard comment:

```
# Sync-tooling state on the source NAS. The client fetches the manifest from here
# EXPLICITLY (no --exclude-from), but bulk syncs must NOT copy it to the target.
# CLIENT-SIDE ONLY — do NOT add to the rsyncd server 'exclude =' (§5.2) or the
# manifest fetch breaks and incremental silently falls back to a full sync.
.nas-sync-state/
```

This also fixes the latent bug: `.sync-manifest.txt`/`.nas-sync-state/` will no longer propagate to NAS A.

### 4.5 Server guard comment — `§5.2 configmap-rsyncd.yaml`

The daemon must keep **serving** the state dir so the client can fetch the manifest. Add a comment above the module `exclude =` line so a future editor does not "tidy" the state dir into it:

```
        # Do NOT add .nas-sync-state/ here — the client fetches the manifest from it.
        # Target-side exclusion is handled CLIENT-side in rsync-exclude.txt (§9A.1).
        exclude = .snapshot/ .snapshots/ .zfs/ @Recently-Snapshot/ @Recycle/ #recycle/ @eaDir/ @tmp/
```

(The server `exclude =` line itself is unchanged.)

### 4.6 Remove the PVC — `§6.1`, `§6.2` apply block, `§14`

- Delete the entire `§6.1 manifest-state-pvc.yaml` block (this removes the `storageClassName` placeholder added earlier in this work session, which becomes moot).
- Renumber the manifest CronJob `§6.2 → §6.1` (it is now the only sub-section of `§6`); update its reference in the `§14` checklist accordingly.
- In the `§6` apply block, remove: `kubectl apply -f cluster-b/manifest-state-pvc.yaml`.
- In the `§14` Cluster B checklist, remove the `manifest-state-pvc.yaml   # 6.1 (incremental only …)` line and fix the `cronjob-manifest.yaml` section number to `# 6.1`.

### 4.7 Doc-consistency edits

- **`§6` intro / `§1` prose:** update any text that describes manifest state as living on a PVC. (Grep `manifest-state-pvc`, `/state`, `PVC` within `§1` and `§6` and reconcile.)
- **"What This Consolidates" table:** replace the row added earlier
  `| Explicit target NFS PV+PVC + manifest StorageClass | (this request) | ✓ (9A.1, 6.1) |`
  with two accurate rows:
  `| Explicit target NFS PV+PVC | (this request) | ✓ (9A.1) |`
  `| Manifest state on source NAS (no PVC) | (this request) | ✓ (§6) |`
- **Section-number sweep:** after the `6.2 → 6.1` renumber, grep the whole guide for `6.2` and `6.1` references (TOC, `§14`, inline prose) and reconcile.

---

## 5. Purge / hygiene (the "scheduled purge")

The scheduled purge is **folded into the producer**, which already runs every 2h:

- Each run `rm -f`s the orphan `last-sync-marker.candidate` (left only by a crashed run).
- `sync-manifest.txt` is **overwritten** every run (never appended) → bounded to one file.
- Fixed filenames → the state dir is structurally bounded to ~3 small files; nothing accumulates.

**Hard rule:** the purge never deletes `last-sync-marker`. Deleting it would force the slow single-stream full sync this design exists to avoid.

A separate dedicated purge CronJob is **not** included: it would be a whole K8s object to remove one occasional temp file already handled by the self-clean. (If an explicit, separately-scheduled purge is ever wanted, a daily Job running `rm -f ${SOURCE_PATH}/.nas-sync-state/last-sync-marker.candidate` would suffice — but it is redundant.)

---

## 6. Migration / cutover

The old marker on the PVC is discarded. On the first manifest run after cutover there is no marker on the NAS, so the producer emits `FULL_SYNC` and the client performs **one** full sync. This is a one-time cost.

**Optional** (to skip that one-time full sync): before deleting the PVC, pre-seed the new marker so incremental resumes immediately, e.g. from inside the manifest pod:

```bash
mkdir -p /mnt/nas-source/.nas-sync-state
# carry over the old reference time if you still have the PVC marker, else 'now':
touch /mnt/nas-source/.nas-sync-state/last-sync-marker
```

Pre-seeding with `now` means changes in the gap between the last real sync and cutover are caught on the *following* run (acceptable); pre-seeding from the old PVC marker's mtime avoids even that gap.

---

## 7. Correctness considerations

- **Client-side vs server-side exclude:** the exclusion lives only in `rsync-exclude.txt` (client). The rsyncd module `exclude =` must keep serving `.nas-sync-state/`; otherwise the explicit manifest fetch fails and incremental silently degrades to full sync. Guard comments in `§5.2` and `§9A.1` enforce this.
- **`find` prune:** pruning the whole `$STATE_DIR` prevents the marker/manifest (touched every run, hence always "newer") from appearing in their own changed-file list.
- **Atomic marker update:** `touch candidate` → `find` → `mv candidate marker` is preserved; `mv` within one NFS directory is an atomic rename.
- **Single writer:** only the manifest CronJob writes state, and `concurrencyPolicy: Forbid` prevents overlap. The client never writes state. No locking needed.
- **Writable source mount:** the manifest pod must mount the source `readOnly: false` (already required for the manifest). Documented at the mount and in `§6`.

---

## 8. Failure modes

| Failure | Effect | Mitigation |
|---------|--------|-----------|
| Source NAS briefly unavailable | Manifest job fails that cycle | Pre-existing dependency; next cycle recovers; no new exposure |
| Source mounted read-only by mistake | State writes fail → no manifest → client FULL_SYNC fallback | `readOnly: false` documented at the mount and in `§6` |
| `.nas-sync-state/` added to server `exclude =` | Manifest fetch fails → client FULL_SYNC fallback (degraded, not broken) | Guard comments in `§5.2` and `§9A.1` |
| Marker lost/corrupted | One full sync, then incremental resumes | Same as today; now on more durable storage |

---

## 9. Open editorial item (not blocking)

Whether to bump the guide from v3.13 (and rename the file) is left to the maintainer. This spec keeps the version label and filename unchanged and records provenance via the "What This Consolidates" table as `(this request)`.

---

## 10. Verification

1. **PVC gone:** `kubectl get pvc -n ea-pmc` no longer lists `manifest-state-pvc`; the manifest pod starts with no `Pending` volume.
2. **State on NAS:** `kubectl exec <manifest-pod> -- ls -la /mnt/nas-source/.nas-sync-state/` shows `last-sync-marker` + `sync-manifest.txt`.
3. **Incremental works across runs:** run the manifest job twice (with a file changed between); second run's manifest is a short changed-file list (not `FULL_SYNC`) and the marker mtime advances.
4. **Exclude works:** after a `standard`/`parallel` client run, `.nas-sync-state/` does **not** appear on NAS A.
5. **Fetch works:** an `incremental` client run logs a successful manifest fetch of `.nas-sync-state/sync-manifest.txt` and syncs only changed files.
6. **Orphan cleanup:** create a stray `.nas-sync-state/last-sync-marker.candidate`, run the job, confirm it is removed and the real marker is intact.
7. **No CRLF regression:** edited fenced scripts remain LF (`cat -A` shows `#!/bin/bash$`, no `^M`).
