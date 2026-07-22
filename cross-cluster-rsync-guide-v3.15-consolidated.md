# Cross-Cluster NAS Rsync — Consolidated Guide v3.15 (Multi-Target, Hardened)

> **This version consolidates everything:**
> - **CRLF-safe build** (dos2unix + build-time verification) — from v3.12
> - **Sidecar self-quit wrapper** (curl/wget/pilot-agent/bash fallbacks) — from v3.11
> - **Two speedup approaches** for 7.4M folders: parallel walk + incremental change-list
> - **Both k8s types** in the deployment YAMLs: CronJob AND Deployment, each able to run any sync mode
>
> **Port:** 8787 | **Delete:** Disabled | **Logging:** Console only | **Namespace:** ea-pmc
>
> **v3.14 added multi-target:** one source NAS B feeds many target clusters. The manifest
> generator does one `find` walk and fans out a **per-client manifest** (keyed by
> `CLIENT_ID`) using a stateless **lookback window** — no marker files to keep in sync.
> (The source NFS mount is still **read-write** for the generator: manifests are written into
> `.nas-sync-state/` on the source NAS. See §S14 in the runbook for a read-only-source setup.)
> Targets are listed in one registry ConfigMap (§6.2); add a target by adding a line (§9A.3).
> See the migration appendix to move an existing v3.13 single-target deployment forward.
>
> **v3.15 hardens it** — four additions and twelve defect fixes, all detailed in
> `docs/reviews/2026-07-22-nas-sync-architecture-review.md`:
> - **`SYNC_MODE=verify`** (§8.10) — drift detection, `--dry-run` only, fails the Job when
>   the target has diverged, so silent drift becomes visible.
> - **Chunked parallel reconcile** (§4.6, §6.3) — server-generated equal-count chunk lists
>   replace the top-level-folder split, with automatic fallback to the old behavior.
> - **Sync status file** (§8.5) — every run records outcome to `.nas-sync-status/` on the
>   target NAS, so "did last night's sync work?" is answerable without pod logs.
> - **Weekly reconcile as a real manifest** (§9A.4) — it is the required compensating control
>   for everything mtime-based detection cannot see (§12.1), not an optional extra.
>
> **One image, selectable behavior** via `SYNC_MODE` env var:
> - `standard` — single rsync (original)
> - `parallel` — N concurrent workers over server chunks, falling back to top-level split
> - `incremental` — sync only changed files via server manifest (skip full walk)
> - `verify` — compare only, transfer nothing, report drift (v3.15)

---

## Table of Contents

1. [How the Pieces Fit Together](#1-how-the-pieces-fit-together)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Step 1 — Cluster B: Build Server Image](#4-step-1--cluster-b-build-server-image)
5. [Step 2 — Cluster B: Deploy rsync Server](#5-step-2--cluster-b-deploy-rsync-server)
6. [Step 3 — Cluster B: Manifest Generator (for incremental)](#6-step-3--cluster-b-manifest-generator)
7. [Step 4 — Cluster B: Verify](#7-step-4--cluster-b-verify)
8. [Step 5 — Cluster A: Build Client Image](#8-step-5--cluster-a-build-client-image)
9. [Step 6A — Cluster A: CronJob Deployment](#9-step-6a--cluster-a-cronjob-deployment)
10. [Step 6B — Cluster A: Deployment (long-running)](#10-step-6b--cluster-a-deployment-long-running)
11. [Step 7 — Verify & Test](#11-step-7--verify--test)
12. [Choosing Sync Mode](#12-choosing-sync-mode)
13. [Troubleshooting](#13-troubleshooting)
14. [File Checklist](#14-file-checklist)

> **Operator procedures live in a separate document.** This guide is the reference — every
> file, every flag, why each exists. For ordered "I need to do X" procedures (greenfield
> bring-up, bulk seed, onboarding a target while others are live, outage recovery, retiring a
> target, triage), see `docs/nas-sync-operations-runbook.md`, which cross-links back into the
> § numbers here.

---

## 1. How the Pieces Fit Together

```
                          CLUSTER A CLIENT IMAGE (one image)
┌────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  Entry layer (chosen by k8s type):                                       │
│   • CronJob      → tini → run-with-sidecar-quit.sh → [sync] → quit proxy │
│   • Deployment   → tini → entrypoint-deployment.sh → cron → [sync loop]  │
│                                                                          │
│  Sync layer (chosen by SYNC_MODE env var), all via dispatch-sync.sh:     │
│   • standard     → nas-sync-client.sh                                    │
│   • parallel     → nas-sync-parallel.sh                                  │
│   • incremental  → nas-sync-incremental.sh                               │
│   • verify       → nas-sync-verify.sh          (v3.15, dry-run only)     │
│                                                                          │
│  dispatch-sync.sh also records the outcome to .nas-sync-status/ on the   │
│  target NAS (v3.15) — every mode gets it for free.                       │
│                                                                          │
│  All scripts: CRLF-stripped at build, LF-verified, +x                    │
└────────────────────────────────────────────────────────────────────────┘
```

Two independent choices:
- **k8s type** (CronJob vs Deployment) → how the container is scheduled/lives
- **SYNC_MODE** (standard/parallel/incremental/verify) → which algorithm runs

Both combine freely. E.g. CronJob+incremental for routine, Deployment+parallel for bulk.

**Multi-target (v3.14):** a third axis — `CLIENT_ID` — selects which per-client manifest a
target pulls. One source daemon + one generator serve all targets; each target is its own
cluster differing only by `CLIENT_ID`, its local NAS, and its registry lookback (§6.2, §9A.3).

**What runs where (v3.15 complete picture):**

| Where | Object | Cadence | Purpose |
|---|---|---|---|
| Cluster B | `nas-sync-server` Deployment | always on | rsyncd on 8787 behind the Istio GW (§5.4) |
| Cluster B | `nas-sync-manifest` CronJob | every 2h | one walk → per-client manifests (§6.1) |
| Cluster B | `nas-sync-chunks` CronJob | weekly | one walk → shared chunk lists for reconcile (§6.3) |
| Cluster A | `nas-sync-client` CronJob | every 2h | routine `incremental` pull (§9A.2) |
| Cluster A | `nas-sync-reconcile` CronJob | weekly | full `parallel` pass — **required**, repairs what mtime cannot see (§9A.4, §12.1) |
| Cluster A | `nas-sync-verify` CronJob | monthly | drift detection, transfers nothing (§9A.5) |

Repeat the Cluster A row set per target, with a distinct `CLIENT_ID` and staggered schedules.

---

## 2. Architecture

```
NAS B (Source)                                              NAS A (Target)
10.90.220.155:/PMCenterData                                 10.19.192.228:/srv/nfs/data
       │                                                           ▲
       │ NFS (read-only)                                           │ NFS (read-write)
       ▼                                                           │
┌──────────────────┐    rsync :8787    ┌──────────────────┐        │
│ Cluster B        │◄──────────────────│ Cluster A        │────────┘
│ Deployment       │  via Istio GW     │ CronJob OR Deploy│
│  (rsync daemon)  │                   │  (sidecar quit)  │
│ + Manifest       │                   │  standard /      │
│   CronJob        │                   │  parallel /      │
│  (for incr mode) │                   │  incremental     │
└──────────────────┘                   └──────────────────┘
```

---

## 3. Prerequisites

| Item | Check |
|------|-------|
| Cluster B → NAS B NFS | `showmount -e 10.90.220.155` |
| Cluster A → NAS A NFS (read-write) | `showmount -e 10.19.192.228` — must list `/srv/nfs/data`, exported `rw` to the node IPs (see note below) |
| Istio on Cluster B | `kubectl get pods -n istio-system` |
| Non-route ingressgateway external IP | `kubectl get svc -n istio-system \| grep gateway` |
| Port 8787 allowed end-to-end | Firewall confirms |
| Registry accessible | Push/pull works |
| `dos2unix` on build machine (optional) | `which dos2unix` |

> **⚠ NAS A export must be writable by the Cluster A nodes.** The target `PersistentVolume`
> (`nas-a-target-pv`, §9A.1) mounts `10.19.192.228:/srv/nfs/data` **read-write** — rsync *pulls*
> into it, so a reachable-but-read-only export breaks every sync. On the NAS A NFS server confirm:
> - **Client ACL includes the worker nodes / pod subnet that mount the PV** — not just your laptop.
>   `showmount -e 10.19.192.228` must list `/srv/nfs/data` for those clients.
> - **Exported `rw`, not `ro`.** A `ro` export fails with `Read-only file system` on first write.
> - **UID/GID mapping is acceptable.** rsync writes as the container UID (root by default). If NAS A
>   uses `root_squash`, writes land as `nobody` — make sure that identity can create/own files under
>   `/srv/nfs/data`, or set `anonuid`/`anongid` (or `no_root_squash`, if your security policy allows).
> - **NFS version matches the PV's `mountOptions`.** The PV requests `nfsvers=4.1`; change it to `3`
>   if NAS A only serves NFSv3 (a mismatch causes a mount/`Pending` failure).
> - **Capacity** is sufficient for the full NAS B dataset (~7.4M folders). The PV `capacity:` is
>   nominal only — real space is whatever NAS A provides.

**Values to substitute:**

```
REGISTRY=your-registry.example.com
NAS_B_IP=10.90.220.155 ; NAS_B_PATH=/PMCenterData
NAS_A_IP=10.19.192.228 ; NAS_A_PATH=/srv/nfs/data
NAMESPACE=ea-pmc
INGRESS_SVC=istio-ingressgateway-nonroute
INGRESS_GW_SELECTOR=ingressgateway-nonroute
ISTIO_EXTERNAL_IP=<from step 4 verify>
SYNC_PASSWORD=YourSecurePassword123!
SYNC_PORT=8787
```

---

## 4. Step 1 — Cluster B: Build Server Image

### 4.1 Create directory

```bash
mkdir -p cluster-b/scripts
cd cluster-b/scripts
```

### 4.2 File: `cluster-b/scripts/entrypoint.sh`

```bash
#!/bin/bash
#############################################
# NAS Sync Server v3.15 — Entrypoint
#############################################
set +e
RSYNC_PORT="${RSYNC_PORT:-8787}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }

log "========================================"
log "NAS Sync Server v3.15 (Cluster B)"
log "  Port: ${RSYNC_PORT} | Source: /mnt/nas-source"
log "========================================"

if [ ! -f /etc/rsyncd.conf ]; then log_error "/etc/rsyncd.conf not found"; exit 1; fi
log "OK rsyncd.conf found"
if [ ! -f /etc/rsyncd.secrets ]; then log_error "/etc/rsyncd.secrets not found"; exit 1; fi
log "OK rsyncd.secrets found"

if mountpoint -q /mnt/nas-source 2>/dev/null; then
    log "OK NAS mounted at /mnt/nas-source"
    df -h /mnt/nas-source | tail -1
else
    log "WARN NAS not detected as mountpoint"
fi

log "--- rsync modules ---"
grep -E '^\[' /etc/rsyncd.conf

log "Starting rsync daemon on port ${RSYNC_PORT}..."
exec rsync --daemon --no-detach --port=${RSYNC_PORT} --log-file=/dev/stdout
```

### 4.3 File: `cluster-b/scripts/generate-manifests.sh`

> Used only for `incremental` mode. One `find` walk → per-client manifests by
> stateless lookback window. The set of clients (and each client's lookback hours)
> comes from the registry ConfigMap mounted at `/userapp/config/clients.txt` (§6.2).

```bash
#!/bin/bash
#############################################
# Multi-Client Manifest Generator (Cluster B) — v3.15
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

mkdir -p "$CLIENTS_DIR"
NOW=$(date +%s)

log "========================================"
log "Multi-Client Manifest Generator v3.15"
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
```

### 4.4 File: `cluster-b/scripts/Dockerfile` (CRLF-safe)

```dockerfile
FROM ubuntu:24.04

LABEL version="3.15"
LABEL description="NAS Sync Server - rsync daemon + manifest + chunks (CRLF-safe)"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    rsync \
    dos2unix \
    tzdata \
    procps \
    iproute2 \
    findutils \
    coreutils \
    nfs-common \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /mnt/nas-source

COPY entrypoint.sh /entrypoint.sh
COPY generate-manifests.sh /userapp/scripts/generate-manifests.sh
COPY generate-chunks.sh /userapp/scripts/generate-chunks.sh

# CRLF-safe: strip carriage returns, set executable
RUN dos2unix /entrypoint.sh \
        /userapp/scripts/generate-manifests.sh \
        /userapp/scripts/generate-chunks.sh \
    && chmod +x /entrypoint.sh \
        /userapp/scripts/generate-manifests.sh \
        /userapp/scripts/generate-chunks.sh

# Fail build if any CRLF remains
RUN for f in /entrypoint.sh \
             /userapp/scripts/generate-manifests.sh \
             /userapp/scripts/generate-chunks.sh; do \
        if head -1 "$f" | grep -q $'\r'; then \
            echo "ERROR: CRLF in $f" && exit 1; \
        fi; \
    done && echo "Scripts verified LF-clean"

# split -n r/N (round-robin on a pipe) requires GNU coreutils 8.8+ — present in ubuntu:24.04.
RUN split --version | head -1

ENV TZ=Asia/Taipei
ENV RSYNC_PORT=8787

EXPOSE 8787

ENTRYPOINT ["/entrypoint.sh"]
```

### 4.5 Build & Push

```bash
cd cluster-b/scripts
# Clean local CRLF first (belt and suspenders)
sed -i 's/\r$//' entrypoint.sh generate-manifests.sh generate-chunks.sh 2>/dev/null || true

docker build -t ${REGISTRY}/nas-sync-server:3.15 .
docker push ${REGISTRY}/nas-sync-server:3.15
```

### 4.6 File: `cluster-b/scripts/generate-chunks.sh` (v3.15)

> Write this file **before** running §4.5 — it is listed in the Dockerfile's COPY and
> CRLF-guard lists (§4.4). Section order is kept stable from v3.14; build order is §4.6 then §4.5.
>
> Used only by `parallel` mode's chunked path. Splits the whole source tree into
> `CHUNK_COUNT` equal-count file lists so reconcile workers pull balanced slices instead of
> whole top-level folders (one oversized folder used to serialize the entire reconcile).
> Chunks are **target-independent** — a pure split of the source tree — so they live under
> `common/` and one weekly walk serves every target. Run by the §6.3 CronJob.

```bash
#!/bin/bash
#############################################
# Chunk Generator (Cluster B) — v3.15
# Full-tree file list split round-robin into
# CHUNK_COUNT equal-count lists, consumed by the
# client's chunked parallel reconcile via
# rsync --files-from=chunk-NNN.txt.
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

TMP_DIR="${STATE_DIR}/common/.chunks.tmp"
OLD_DIR="${STATE_DIR}/common/.chunks.old"

log "========================================"
log "Chunk Generator v3.15"
log "  Source: $SOURCE_PATH"
log "  Chunks: $CHUNKS_DIR (count=$CHUNK_COUNT)"
log "========================================"

# Hygiene: drop orphan dirs from a crashed run.
# Safe because the CronJob uses concurrencyPolicy: Forbid (no concurrent run).
rm -rf "$TMP_DIR" "$OLD_DIR"
mkdir -p "$TMP_DIR" || { log "ERROR: cannot create $TMP_DIR (source NAS writable?)"; exit 1; }

NOW=$(date +%s)

# Same prune set as the manifest generator (§4.3): snapshot dirs at EVERY depth.
log "Walking source (one pass)..."
find "$SOURCE_PATH" \
    -name '.snapshot'  -prune -o \
    -name '.snapshots' -prune -o \
    -name '.zfs'       -prune -o \
    -name '@eaDir'     -prune -o \
    -path "$STATE_DIR" -prune -o \
    \( -type f -o -type l \) -printf '%P\n' 2>/dev/null \
| split -n "r/${CHUNK_COUNT}" -d -a 3 - "${TMP_DIR}/chunk-"
# split -n r/N = round-robin by line, works on a pipe (no need to know the total first).
# Round-robin also spreads any directory hot-spot evenly across chunks.

TOTAL=0
for f in "${TMP_DIR}"/chunk-*; do
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

printf 'generated_at=%s\nchunk_count=%s\ntotal_files=%s\n' \
    "$NOW" "$CHUNK_COUNT" "$TOTAL" > "${TMP_DIR}/chunks.meta"

# Swap into place. Clients fetch the whole dir in one rsync, so the worst case during
# the swap is one failed fetch — the client then falls back to the top-level split (§8.3).
if [ -d "$CHUNKS_DIR" ]; then
    mv -f "$CHUNKS_DIR" "$OLD_DIR" || { log "ERROR: cannot rotate old chunks"; exit 1; }
fi
mkdir -p "$(dirname "$CHUNKS_DIR")"
mv -f "$TMP_DIR" "$CHUNKS_DIR" || { log "ERROR: cannot publish chunks"; exit 1; }
rm -rf "$OLD_DIR"

log "Published $CHUNK_COUNT chunks, $TOTAL files total → $CHUNKS_DIR"
log "Done."
```

> **Disk cost.** At 7.4M paths the chunk lists total a few hundred MB on the source NAS under
> `.nas-sync-state/common/chunks/`. That path is already excluded client-side (§9A.1), so it is
> never replicated. To reclaim it if you stop using chunked reconcile:
> `rm -rf /mnt/nas-source/.nas-sync-state/common/chunks` from a server pod.

---

## 5. Step 2 — Cluster B: Deploy rsync Server

```bash
kubectl config use-context cluster-b
```

### 5.1 namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ea-pmc
  labels:
    app: nas-sync
```

### 5.2 configmap-rsyncd.yaml

> Note `reverse lookup = no` (fixes the 127.0.0.6 DNS stall). Only the `[nas-data]` module is needed — incremental mode's manifest + sync-state live on the source NAS under `.nas-sync-state/` (written by the §6 CronJob), not in a separate rsyncd module.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rsyncd-config
  namespace: ea-pmc
data:
  rsyncd.conf: |
    uid = root
    gid = root
    use chroot = no
    max connections = 20
    timeout = 600
    reverse lookup = no
    pid file = /var/run/rsyncd.pid
    lock file = /var/run/rsync.lock
    log file = /dev/stdout
    log format = %t %m %f %b

    [nas-data]
        path = /mnt/nas-source
        comment = NAS B Data (Source)
        read only = yes
        list = yes
        auth users = syncuser
        secrets file = /etc/rsyncd.secrets
        hosts allow = *
        # Do NOT add .nas-sync-state/ here — the client fetches the manifest from it.
        # Target-side exclusion is handled CLIENT-side in rsync-exclude.txt (§9A.1).
        exclude = .snapshot/ .snapshots/ .zfs/ @Recently-Snapshot/ @Recycle/ #recycle/ @eaDir/ @tmp/
        dont compress = *.gz *.tgz *.zip *.z *.Z *.rpm *.deb *.bz2 *.xz *.rar *.7z
```

### 5.3 secret-password.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rsync-secrets
  namespace: ea-pmc
type: Opaque
stringData:
  rsyncd.secrets: |
    syncuser:YourSecurePassword123!
```

### 5.4 deployment-server.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nas-sync-server
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nas-sync
      role: server
  template:
    metadata:
      labels:
        app: nas-sync
        role: server
    spec:
      containers:
        - name: nas-sync-server
          image: your-registry.example.com/nas-sync-server:3.15    # ◄ MODIFY
          imagePullPolicy: Always
          ports:
            - name: tcp-rsync
              containerPort: 8787
              protocol: TCP
          env:
            - name: TZ
              value: "Asia/Taipei"
            - name: RSYNC_PORT
              value: "8787"
          volumeMounts:
            - name: nas-source
              mountPath: /mnt/nas-source
              # Must be read-write for incremental: the manifest + sync-state are
              # written into the source NAS under .nas-sync-state/ (§6). standard
              # and parallel modes can run against a read-only source.
            - name: rsyncd-config
              mountPath: /etc/rsyncd.conf
              subPath: rsyncd.conf
              readOnly: true
            - name: rsync-secrets
              mountPath: /etc/rsyncd.secrets
              subPath: rsyncd.secrets
              readOnly: true
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "2Gi"
              cpu: "1000m"
          livenessProbe:
            tcpSocket:
              port: 8787
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            tcpSocket:
              port: 8787
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: nas-source
          nfs:
            server: "10.90.220.155"          # ◄ MODIFY
            path: "/PMCenterData"            # ◄ MODIFY
            readOnly: false                  # false if incremental writes manifest here
        - name: rsyncd-config
          configMap:
            name: rsyncd-config
        - name: rsync-secrets
          secret:
            secretName: rsync-secrets
            defaultMode: 0600
      restartPolicy: Always
```

### 5.5 service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nas-sync-server
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: server
spec:
  type: ClusterIP
  ports:
    - name: tcp-rsync
      port: 8787
      targetPort: 8787
      protocol: TCP
  selector:
    app: nas-sync
    role: server
```

### 5.6 gateway.yaml

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: nas-sync-gateway
  namespace: ea-pmc
spec:
  selector:
    istio: ingressgateway-nonroute            # ◄ MODIFY
  servers:
    - port:
        number: 8787
        name: tcp-rsync
        protocol: TCP
      hosts:
        - "*"
```

### 5.7 virtualservice.yaml

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: nas-sync-vs
  namespace: ea-pmc
spec:
  hosts:
    - "*"
  gateways:
    - nas-sync-gateway
  tcp:
    - match:
        - port: 8787
      route:
        - destination:
            host: nas-sync-server.ea-pmc.svc.cluster.local
            port:
              number: 8787
```

### 5.8 Apply + Patch IngressGateway

```bash
kubectl apply -f cluster-b/namespace.yaml
kubectl apply -f cluster-b/configmap-rsyncd.yaml
kubectl apply -f cluster-b/secret-password.yaml
kubectl apply -f cluster-b/deployment-server.yaml
kubectl apply -f cluster-b/service.yaml
kubectl apply -f cluster-b/gateway.yaml
kubectl apply -f cluster-b/virtualservice.yaml

# Add port 8787 to non-route ingressgateway
INGRESS_SVC=istio-ingressgateway-nonroute     # ◄ MODIFY
kubectl patch svc $INGRESS_SVC -n istio-system --type='json' -p='[
  {"op":"add","path":"/spec/ports/-","value":{"name":"tcp-rsync","port":8787,"targetPort":8787,"protocol":"TCP"}}
]'
```

---

## 6. Step 3 — Cluster B: Manifest Generator

> **Only needed if you use `incremental` mode.** Skip if using `standard` or `parallel`.

### 6.1 cronjob-manifests.yaml + client registry

```yaml
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
              image: your-registry.example.com/nas-sync-server:3.15   # ◄ reuse server image
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

> **Sizing `lookback_hours`.** It must cover **pull period + worst tolerated client outage**,
> and it must exceed the generator's own walk time. The generator captures its threshold at
> *start* of the walk but publishes at the *end*, so a client that polls mid-walk reads the
> previous manifest — a lookback of merely 1× the pull period will drop changes. Pull period
> × 2–3 is the safe default. A client outage **longer** than its lookback loses those changes
> until the weekly reconcile (§9A.4) repairs them; see §12.1 and runbook scenario S8.

### 6.3 cronjob-chunks.yaml (v3.15, for chunked parallel reconcile)

> Only needed if you use `parallel` mode (the weekly reconcile, §9A.4). Without it the
> reconcile still works — `nas-sync-parallel.sh` falls back to the v3.14 top-level-folder
> split (§8.3). Schedule it a few hours **before** the reconcile so chunks are fresh.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nas-sync-chunks
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: chunks
spec:
  # Weekly, ~2h before the client's weekly reconcile (§9A.4 runs Sun 02:00).
  schedule: "0 0 * * 0"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 3600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 86400
      backoffLimit: 1
      template:
        metadata:
          annotations:
            sidecar.istio.io/inject: "false"
        spec:
          containers:
            - name: chunk-gen
              image: your-registry.example.com/nas-sync-server:3.15   # ◄ reuse server image
              command: ["/bin/bash", "/userapp/scripts/generate-chunks.sh"]
              env:
                - name: SOURCE_PATH
                  value: "/mnt/nas-source"
                - name: STATE_DIR
                  value: "/mnt/nas-source/.nas-sync-state"
                - name: CHUNK_COUNT
                  value: "24"      # ◄ more chunks than workers, so fast workers keep pulling
              volumeMounts:
                - name: nas-source
                  mountPath: /mnt/nas-source
              resources:
                requests:
                  memory: "512Mi"
                  cpu: "200m"
                limits:
                  memory: "2Gi"
                  cpu: "1000m"
          restartPolicy: Never
          volumes:
            - name: nas-source
              nfs:
                server: "10.90.220.155"          # ◄ MODIFY
                path: "/PMCenterData"            # ◄ MODIFY
                readOnly: false                  # REQUIRED: chunk lists are written here
```

```bash
# Only if using chunked parallel reconcile:
kubectl apply -f cluster-b/cronjob-chunks.yaml
```

---

## 7. Step 4 — Cluster B: Verify

```bash
kubectl get pods -n ea-pmc -l app=nas-sync,role=server
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- ss -tlnp | grep 8787
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- rsync --list-only rsync://localhost:8787/nas-data/ | head
kubectl get svc $INGRESS_SVC -n istio-system -o jsonpath='{range .spec.ports[*]}{.name}:{.port}{"\n"}{end}' | grep 8787
nc -zv ${ISTIO_EXTERNAL_IP} 8787

# (incremental) confirm a manifest exists per registered client:
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  sh -c 'for d in /mnt/nas-source/.nas-sync-state/clients/*/; do \
    echo "$d: $(wc -l < "$d/sync-manifest.txt" 2>/dev/null || echo MISSING) files"; done'
```

---

## 8. Step 5 — Cluster A: Build Client Image

The client image bundles all sync scripts + both entry layers + CRLF-safe build.

### 8.1 Create directory

```bash
mkdir -p cluster-a/scripts
cd cluster-a/scripts
```

### 8.2 File: `cluster-a/scripts/nas-sync-client.sh` (standard mode)

```bash
#!/bin/bash
#############################################
# NAS Sync — STANDARD mode (single rsync)
#############################################
set +e

REMOTE_HOST="${REMOTE_HOST:-nas-sync.cluster-b.example.com}"
REMOTE_PORT="${REMOTE_PORT:-8787}"
REMOTE_MODULE="${REMOTE_MODULE:-nas-data}"
REMOTE_USER="${REMOTE_USER:-syncuser}"
LOCAL_NAS_PATH="${LOCAL_NAS_PATH:-/mnt/nas-target}"
SYNC_DIRECTION="${SYNC_DIRECTION:-pull}"
RSYNC_PASSWORD_FILE="${RSYNC_PASSWORD_FILE:-/userapp/config/rsync.password}"
EXCLUDE_FILE="${EXCLUDE_FILE:-/userapp/config/rsync-exclude.txt}"
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-14400}"

REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"

PREFLIGHT_RETRIES="${PREFLIGHT_RETRIES:-10}"
PREFLIGHT_WAIT="${PREFLIGHT_WAIT:-6}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

# v3.15: rsync 23/24 are NORMAL on a live source (files vanish mid-run). Treating them
# as failure makes every healthy run show Failed and burns backoffLimit retries.
rsync_rc_ok() {
    case "$1" in
        0)  return 0 ;;
        24) log "NOTE: rc=24 (some source files vanished during transfer) — treated as success" ; return 0 ;;
        23) log "WARN: rc=23 (partial transfer; some files unreadable) — treated as success, check log above" ; return 0 ;;
        *)  return 1 ;;
    esac
}

# v3.15: wait for the Istio sidecar to start routing. Even with
# holdApplicationUntilProxyStarts (§9A.2) this covers clusters where the annotation
# is not permitted — otherwise a cold start dies with a false "Remote not reachable".
wait_for_remote() {
    local i=1
    while [ "$i" -le "$PREFLIGHT_RETRIES" ]; do
        nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null && return 0
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES}) — sidecar may still be starting"
        sleep "$PREFLIGHT_WAIT"
        i=$((i+1))
    done
    return 1
}

# --whole-file (faster over proxy), no -v (quiet), no --delete
# v3.15: --partial-dir keeps interrupted transfers OUT of the visible tree. With bare
# --partial, rsync leaves truncated data at the real filename on NAS A, where readers
# see a corrupt-looking file. .rsync-partial/ is already in the exclude list (§9A.1).
RSYNC_FLAGS="-a --whole-file --partial --partial-dir=.rsync-partial --stats --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

START=$(date +%s)
log "=== NAS SYNC (standard) ==="
log "Remote: $REMOTE_URL/ → $LOCAL_NAS_PATH"

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
wait_for_remote || die "Remote not reachable after ${PREFLIGHT_RETRIES} attempts"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

if [ "$SYNC_DIRECTION" = "pull" ]; then
    rsync $RSYNC_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
else
    rsync $RSYNC_FLAGS "${LOCAL_NAS_PATH}/" "${REMOTE_URL}/" 2>&1
fi
RC=${PIPESTATUS[0]}

rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: rsync_rc=$RC exit=$SYNC_EXIT, ${DUR}s ==="
exit $SYNC_EXIT
```

### 8.3 File: `cluster-a/scripts/nas-sync-parallel.sh` (parallel mode)

```bash
#!/bin/bash
#############################################
# NAS Sync — PARALLEL mode (v3.15)
# Preferred: N workers over server-generated
#   equal-count chunk lists (§4.6 / §6.3)
# Fallback:  N workers split by top-level folder
#   (v3.14 behavior) when chunks are missing or
#   stale — a failed chunk job never blocks a run.
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

WORK_DIR="/tmp/nas-sync-parallel.$$"
FOLDER_LIST="${WORK_DIR}/folders.txt"
CHUNK_DIR="${WORK_DIR}/chunks"
RC_DIR="${WORK_DIR}/rc"
REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

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
        i=$((i+1))
    done
    return 1
}

# --partial-dir: keep interrupted transfers out of the visible tree (§8.2).
RSYNC_FLAGS="-a --whole-file --partial --partial-dir=.rsync-partial --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$CHUNK_DIR" "$RC_DIR" || die "Cannot create $WORK_DIR"

START=$(date +%s)
log "=== NAS SYNC (parallel, $PARALLEL_WORKERS workers) ==="

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
wait_for_remote || die "Remote not reachable after ${PREFLIGHT_RETRIES} attempts"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

export REMOTE_URL LOCAL_NAS_PATH RSYNC_FLAGS CHUNK_DIR RC_DIR

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
sync_one_folder() {
    local folder="$1"
    local s; s=$(date +%s)
    echo "$(date '+%H:%M:%S') [worker] START $folder"
    rsync $RSYNC_FLAGS "${REMOTE_URL}/${folder}/" "${LOCAL_NAS_PATH}/${folder}/" 2>&1 | sed "s/^/[$folder] /"
    local rc=${PIPESTATUS[0]}
    echo "$rc" > "${RC_DIR}/$(echo "$folder" | tr '/' '_')"
    echo "$(date '+%H:%M:%S') [worker] DONE  $folder (rc=$rc, $(( $(date +%s) - s ))s)"
}
export -f sync_one_folder

# ---- Try the chunked path (server-generated equal-count chunks, §4.6) ----
USE_CHUNKS=false
log "Fetching chunk lists from ${CHUNKS_REMOTE}/ ..."
rsync -a --password-file="$RSYNC_PASSWORD_FILE" \
    "${REMOTE_URL}/${CHUNKS_REMOTE}/" "${CHUNK_DIR}/" >/dev/null 2>&1
FETCH_RC=$?

if [ "$FETCH_RC" -ne 0 ] || [ ! -f "${CHUNK_DIR}/chunks.meta" ]; then
    log "No chunk lists available (rc=$FETCH_RC) — falling back to top-level split"
else
    GEN_AT=$(awk -F= '/^generated_at=/{print $2}' "${CHUNK_DIR}/chunks.meta")
    case "$GEN_AT" in ''|*[!0-9]*) GEN_AT=0 ;; esac
    AGE=$(( $(date +%s) - GEN_AT ))
    if [ "$GEN_AT" -eq 0 ] || [ "$AGE" -gt "$CHUNK_MAX_AGE" ]; then
        log "Chunks are stale (age=${AGE}s > ${CHUNK_MAX_AGE}s) — falling back to top-level split"
    else
        NCHUNK=$(ls -1 "${CHUNK_DIR}"/chunk-*.txt 2>/dev/null | wc -l | tr -d ' ')
        if [ "$NCHUNK" -gt 0 ]; then
            USE_CHUNKS=true
            log "Using $NCHUNK server-generated chunks (age=${AGE}s, $(awk -F= '/^total_files=/{print $2}' "${CHUNK_DIR}/chunks.meta") files total)"
        else
            log "chunks.meta present but no chunk-*.txt — falling back to top-level split"
        fi
    fi
fi

if [ "$USE_CHUNKS" = true ]; then
    UNIT="chunks"
    UNIT_COUNT="$NCHUNK"
    ls -1 "${CHUNK_DIR}"/chunk-*.txt \
        | xargs -P "$PARALLEL_WORKERS" -I {} bash -c 'sync_one_chunk "$@"' _ {}
else
    UNIT="folders"
    log "Listing top-level folders..."
    rsync --list-only --password-file="$RSYNC_PASSWORD_FILE" "${REMOTE_URL}/" 2>/dev/null \
        | awk '$1 ~ /^d/ && $NF != "." {print $NF}' > "$FOLDER_LIST"
    UNIT_COUNT=$(wc -l < "$FOLDER_LIST" | tr -d ' ')
    log "Found $UNIT_COUNT top-level folders"
    [ "$UNIT_COUNT" -gt 0 ] || die "No folders found"

    log "Syncing top-level loose files..."
    rsync $RSYNC_FLAGS --dirs "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1 | grep -v '^$'

    xargs -P "$PARALLEL_WORKERS" -I {} bash -c 'sync_one_folder "$@"' _ {} < "$FOLDER_LIST"
fi

# ---- Tally worker results: one bad worker must not hide the others ----
FAILED=""
FAIL_COUNT=0
for f in "${RC_DIR}"/*; do
    [ -f "$f" ] || continue
    rc=$(cat "$f")
    if ! rsync_rc_ok "$rc"; then
        FAILED="$FAILED $(basename "$f")(rc=$rc)"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
done

DUR=$(( $(date +%s) - START ))
if [ "$FAIL_COUNT" -gt 0 ]; then
    log_error "$FAIL_COUNT/$UNIT_COUNT $UNIT failed:$FAILED"
    log "=== COMPLETE: $UNIT_COUNT $UNIT, ${DUR}s, FAILED=$FAIL_COUNT ==="
    exit 1
fi

log "=== COMPLETE: $UNIT_COUNT $UNIT, ${DUR}s, all OK ==="
exit 0
```

> **Why chunks beat the top-level split.** The v3.14 split gave each worker one top-level
> folder, so a single oversized folder serialized the whole reconcile — 6 workers, but the
> run is as long as its biggest folder. Chunks are equal *file counts*, round-robined, and
> deliberately outnumber the workers (24 chunks / 6 workers), so fast workers keep pulling
> new work until the list is empty. If the chunk job has not run, is stale, or its output is
> unreachable, the script logs the reason and uses the v3.14 behavior — the reconcile always
> runs.

### 8.4 File: `cluster-a/scripts/nas-sync-incremental.sh` (incremental mode)

```bash
#!/bin/bash
#############################################
# NAS Sync — INCREMENTAL mode (v3.15)
# Sync only changed files from server manifest.
# See §12.1 for what mtime detection cannot see —
# the weekly reconcile (§9A.4) is REQUIRED.
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
PREFLIGHT_RETRIES="${PREFLIGHT_RETRIES:-10}"
PREFLIGHT_WAIT="${PREFLIGHT_WAIT:-6}"
# Fail the run if the generator has clearly stopped (manifest older than this).
# Without it a dead generator is invisible: the client keeps re-syncing the same
# stale manifest and reports success while new changes are never picked up.
MANIFEST_MAX_AGE="${MANIFEST_MAX_AGE:-86400}"

# Per-client manifest path (multi-target). CLIENT_ID must match a registry line (§6.2).
CLIENT_ID="${CLIENT_ID:-}"
if [ -n "$CLIENT_ID" ]; then
    MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/clients/${CLIENT_ID}/sync-manifest.txt}"
    META_NAME="${META_NAME:-.nas-sync-state/clients/${CLIENT_ID}/manifest.meta}"
else
    MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"
    META_NAME=""
fi

# v3.15: unique per-run work dir. v3.14 used a fixed /tmp path, so in a long-lived
# Deployment pod a FAILED fetch left the PREVIOUS run's manifest in place — the
# existence check passed and the client silently re-synced an old change list,
# skipping everything that changed in the current window.
WORK_DIR="/tmp/nas-sync-incremental.$$"
MANIFEST_LOCAL="${WORK_DIR}/sync-manifest.txt"
META_LOCAL="${WORK_DIR}/manifest.meta"
REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

# rsync 23/24 are normal on a live source — see §8.2.
rsync_rc_ok() {
    case "$1" in
        0)  return 0 ;;
        24) log "NOTE: rc=24 (some source files vanished during transfer) — treated as success" ; return 0 ;;
        23) log "WARN: rc=23 (partial transfer; some files unreadable) — treated as success" ; return 0 ;;
        *)  return 1 ;;
    esac
}

wait_for_remote() {
    local i=1
    while [ "$i" -le "$PREFLIGHT_RETRIES" ]; do
        nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null && return 0
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES}) — sidecar may still be starting"
        sleep "$PREFLIGHT_WAIT"
        i=$((i+1))
    done
    return 1
}

# --partial-dir: keep interrupted transfers out of the visible tree (§8.2).
RSYNC_FLAGS="-a --whole-file --partial --partial-dir=.rsync-partial --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR" || die "Cannot create $WORK_DIR"

START=$(date +%s)
log "=== NAS SYNC (incremental) client=${CLIENT_ID:-<legacy>} ==="
[ -n "$CLIENT_ID" ] || log "WARN: CLIENT_ID is empty — using the pre-v3.14 single-target manifest path. On a v3.14+ server this path does not exist and every run will degrade to a FULL sync."

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
wait_for_remote || die "Remote not reachable after ${PREFLIGHT_RETRIES} attempts"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

run_full_sync() {
    rsync $RSYNC_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
    return ${PIPESTATUS[0]}
}

log "Fetching manifest ($MANIFEST_NAME)..."
rsync -a --password-file="$RSYNC_PASSWORD_FILE" \
    "${REMOTE_URL}/${MANIFEST_NAME}" "$MANIFEST_LOCAL" 2>&1
FETCH_RC=$?

# v3.15: trust the EXIT CODE, not just the file's existence.
if [ "$FETCH_RC" -ne 0 ] || [ ! -s "$MANIFEST_LOCAL" ]; then
    log "Manifest fetch failed (rc=$FETCH_RC) — FULL sync fallback"
    run_full_sync
    RC=$?
    rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC
    DUR=$(( $(date +%s) - START ))
    log "=== COMPLETE: mode=full-fallback rsync_rc=$RC exit=$SYNC_EXIT, ${DUR}s ==="
    exit $SYNC_EXIT
fi

# v3.15: is the generator still alive? A stale manifest means new changes are never seen.
if [ -n "$META_NAME" ]; then
    rsync -a --password-file="$RSYNC_PASSWORD_FILE" \
        "${REMOTE_URL}/${META_NAME}" "$META_LOCAL" >/dev/null 2>&1
    if [ -s "$META_LOCAL" ]; then
        GEN_AT=$(awk -F= '/^generated_at=/{print $2}' "$META_LOCAL")
        case "$GEN_AT" in ''|*[!0-9]*) GEN_AT=0 ;; esac
        if [ "$GEN_AT" -gt 0 ]; then
            AGE=$(( $(date +%s) - GEN_AT ))
            log "Manifest generated ${AGE}s ago"
            if [ "$AGE" -gt "$MANIFEST_MAX_AGE" ]; then
                die "Manifest is STALE (${AGE}s > ${MANIFEST_MAX_AGE}s) — the generator CronJob on Cluster B has stopped. Syncing it would report false success while new changes go unseen. Fix the generator (§6.1), then re-run."
            fi
        fi
    else
        log "WARN: manifest.meta unavailable — cannot verify generator freshness"
    fi
fi

if grep -q "^FULL_SYNC$" "$MANIFEST_LOCAL"; then
    log "FULL_SYNC signaled (first run for this client)"
    run_full_sync
    RC=$?
else
    CHANGED=$(grep -vc '^$' "$MANIFEST_LOCAL")
    log "Incremental: $CHANGED changed files"
    if [ "$CHANGED" -eq 0 ]; then
        log "Nothing changed. Skipping."
        RC=0
    else
        rsync $RSYNC_FLAGS --files-from="$MANIFEST_LOCAL" \
            "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
        RC=${PIPESTATUS[0]}
    fi
fi

rsync_rc_ok "$RC" && SYNC_EXIT=0 || SYNC_EXIT=$RC

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: rsync_rc=$RC exit=$SYNC_EXIT, ${DUR}s ==="
exit $SYNC_EXIT
```

### 8.5 File: `cluster-a/scripts/dispatch-sync.sh` (mode selector)

> Central dispatcher — picks the sync script based on `SYNC_MODE`, then records the outcome
> to `.nas-sync-status/` on the **target** NAS (v3.15). Because the dispatcher owns this,
> every mode gets status reporting for free, and each target's status lives on its own NAS —
> per-target by construction, no extra configuration.

```bash
#!/bin/bash
#############################################
# Dispatch — selects sync script by SYNC_MODE,
# then records outcome to the target NAS.
#############################################
SYNC_MODE="${SYNC_MODE:-standard}"
LOCAL_NAS_PATH="${LOCAL_NAS_PATH:-/mnt/nas-target}"
STATUS_DIR="${STATUS_DIR:-${LOCAL_NAS_PATH}/.nas-sync-status}"
STATUS_ENABLED="${STATUS_ENABLED:-true}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [dispatch] $1"; }

case "$SYNC_MODE" in
    parallel)    SCRIPT=/userapp/scripts/nas-sync-parallel.sh ;;
    incremental) SCRIPT=/userapp/scripts/nas-sync-incremental.sh ;;
    verify)      SCRIPT=/userapp/scripts/nas-sync-verify.sh ;;
    standard)    SCRIPT=/userapp/scripts/nas-sync-client.sh ;;
    *)
        log "WARN: unknown SYNC_MODE '$SYNC_MODE' — falling back to standard"
        SYNC_MODE=standard
        SCRIPT=/userapp/scripts/nas-sync-client.sh
        ;;
esac

log "Mode: $SYNC_MODE"
START=$(date +%s)
"$SCRIPT"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
log "Mode $SYNC_MODE finished: exit=$RC elapsed=${ELAPSED}s"

# ---- Status file (v3.15) ----
# Answers "did last night's sync work?" without pod logs, which age out with
# successfulJobsHistoryLimit. A status write failure NEVER changes the sync outcome.
write_status() {
    local name="$1" line="$2" tmp
    tmp="${STATUS_DIR}/.${name}.$$"
    printf '%s\n' "$line" > "$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "${STATUS_DIR}/${name}" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

if [ "$STATUS_ENABLED" = "true" ]; then
    if mkdir -p "$STATUS_DIR" 2>/dev/null; then
        LINE="ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ') mode=${SYNC_MODE} client=${CLIENT_ID:-none} exit=${RC} elapsed=${ELAPSED}s host=$(hostname)"
        write_status "last-run" "$LINE" || log "WARN: could not write ${STATUS_DIR}/last-run (sync result unaffected)"
        if [ "$RC" -eq 0 ]; then
            write_status "last-success" "$LINE" || log "WARN: could not write ${STATUS_DIR}/last-success (sync result unaffected)"
        fi
    else
        log "WARN: could not create $STATUS_DIR (sync result unaffected)"
    fi
fi

exit $RC
```

> **Reading it.** From any pod with the target PVC mounted:
> `cat /mnt/nas-target/.nas-sync-status/last-success`. Rule of thumb: if `last-success` is
> older than **2× the CronJob interval**, investigate (§13). `last-run` newer than
> `last-success` means the most recent attempt failed.

### 8.6 File: `cluster-a/scripts/run-with-sidecar-quit.sh` (CronJob wrapper)

```bash
#!/bin/bash
#############################################
# Wrapper — runs sync (via dispatch), then
# quits istio-proxy so the Job pod completes.
#############################################
set +e

ISTIO_ADMIN_HOST="${ISTIO_ADMIN_HOST:-127.0.0.1}"
ISTIO_ADMIN_PORT="${ISTIO_ADMIN_PORT:-15020}"
SIDECAR_QUIT_ENABLED="${SIDECAR_QUIT_ENABLED:-true}"
SIDECAR_QUIT_TIMEOUT="${SIDECAR_QUIT_TIMEOUT:-10}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [wrapper] $1"; }

log "=== Wrapper start (SYNC_MODE=${SYNC_MODE:-standard}) ==="
/userapp/scripts/dispatch-sync.sh
SYNC_EXIT=$?
log "Sync exited: $SYNC_EXIT"

if [ "$SIDECAR_QUIT_ENABLED" != "true" ]; then
    exit $SYNC_EXIT
fi

if ! nc -z -w 3 "$ISTIO_ADMIN_HOST" "$ISTIO_ADMIN_PORT" 2>/dev/null; then
    log "No sidecar admin port — skipping quit"
    exit $SYNC_EXIT
fi
log "Quitting istio-proxy..."

QUIT_OK=false
# Method 1: curl
if command -v curl >/dev/null 2>&1; then
    curl -fsS -m "$SIDECAR_QUIT_TIMEOUT" -X POST \
        "http://${ISTIO_ADMIN_HOST}:${ISTIO_ADMIN_PORT}/quitquitquit" 2>/dev/null \
        && { log "[1] curl OK"; QUIT_OK=true; }
fi
# Method 2: wget
if [ "$QUIT_OK" != true ] && command -v wget >/dev/null 2>&1; then
    wget -q -O - --timeout="$SIDECAR_QUIT_TIMEOUT" --method=POST \
        "http://${ISTIO_ADMIN_HOST}:${ISTIO_ADMIN_PORT}/quitquitquit" 2>/dev/null \
        && { log "[2] wget OK"; QUIT_OK=true; }
fi
# Method 3: pilot-agent
if [ "$QUIT_OK" != true ] && command -v pilot-agent >/dev/null 2>&1; then
    timeout "$SIDECAR_QUIT_TIMEOUT" pilot-agent request POST /quitquitquit 2>/dev/null \
        && { log "[3] pilot-agent OK"; QUIT_OK=true; }
fi
# Method 4: bash /dev/tcp
if [ "$QUIT_OK" != true ]; then
    timeout "$SIDECAR_QUIT_TIMEOUT" bash -c \
        "exec 3<>/dev/tcp/${ISTIO_ADMIN_HOST}/${ISTIO_ADMIN_PORT} && \
         printf 'POST /quitquitquit HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' >&3 && \
         cat <&3 | head -1" 2>/dev/null | grep -q "HTTP" \
        && { log "[4] bash /dev/tcp OK"; QUIT_OK=true; }
fi

[ "$QUIT_OK" = true ] && log "Sidecar quit signal sent" || log "WARN: all quit methods failed"

# Wait for sidecar to exit
for i in $(seq 1 15); do
    nc -z -w 1 "$ISTIO_ADMIN_HOST" "$ISTIO_ADMIN_PORT" 2>/dev/null || { log "Sidecar gone after ${i}s"; break; }
    sleep 1
done

log "=== Final exit: $SYNC_EXIT ==="
exit $SYNC_EXIT
```

### 8.7 File: `cluster-a/scripts/entrypoint-deployment.sh` (Deployment entry)

```bash
#!/bin/bash
#############################################
# Deployment entry — initial sync + cron loop
# Sidecar NOT quit (pod runs forever)
#############################################
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

CRON_SCHEDULE="${CRON_SCHEDULE:-0 */2 * * *}"

log "=== NAS Sync Client v3.15 (Deployment, SYNC_MODE=${SYNC_MODE:-standard}) ==="
log "Cron: ${CRON_SCHEDULE}"
log "Client: ${CLIENT_ID:-<unset>}"

# v3.15: CLIENT_ID and VERIFY_/CHUNK_/STATUS_/PREFLIGHT_ added to the allow-list.
# v3.14 omitted CLIENT_ID, so cron runs lost it and incremental mode silently fell
# back to the pre-v3.14 manifest path — i.e. a FULL sync on every single cycle.
# Values are quoted so entries containing spaces survive `. /etc/environment`.
printenv \
  | grep -E '^(REMOTE_|LOCAL_|SYNC_|RSYNC_|EXCLUDE_|CHECK_|TZ|PARALLEL_|MANIFEST_|CLIENT_ID|VERIFY_|CHUNK_|STATUS_|PREFLIGHT_)' \
  | sed 's/^\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)$/\1="\2"/' > /etc/environment
chmod 0600 /etc/environment

# v3.15: flock prevents overlapping runs. concurrencyPolicy: Forbid protects the CronJob
# path only — nothing guarded this one, so a sync longer than CRON_SCHEDULE stacked a
# second rsync onto the same target tree.
# v3.15: written to /etc/cron.d ONLY. v3.14 also ran `crontab` on this same file; that
# format carries a user field ("root") which a user crontab must not have, so cron parsed
# "root" as the command and logged an error every tick alongside the real run.
cat > /etc/cron.d/nas-sync << EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${CRON_SCHEDULE} root . /etc/environment && flock -n /var/lock/nas-sync.lock /userapp/scripts/dispatch-sync.sh > /proc/1/fd/1 2>/proc/1/fd/2
EOF
chmod 0644 /etc/cron.d/nas-sync
log "OK Cron configured (/etc/cron.d/nas-sync, flock-guarded)"

log "=== INITIAL SYNC (no time limit) ==="
flock -n /var/lock/nas-sync.lock /userapp/scripts/dispatch-sync.sh
log "Initial sync done (exit $?). Starting cron..."

exec cron -f
```

> **Deployment mode and `incremental`.** If you set `SYNC_MODE=incremental` here, you must
> also set `CLIENT_ID` in the Deployment manifest (§10B.1) — it is not optional, and without
> it every run degrades to a full sync. The `wait_for_remote` retry in the mode scripts
> matters less here (the pod is long-lived and the sidecar is up by the time cron fires) but
> is still used on the initial sync, which starts immediately at pod boot.

### 8.8 File: `cluster-a/scripts/Dockerfile` (CRLF-safe, all scripts)

```dockerfile
FROM ubuntu:24.04

LABEL version="3.15"
LABEL description="NAS Sync Client - all modes incl. verify, both k8s types, CRLF-safe"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    rsync \
    cron \
    tini \
    bash \
    curl \
    wget \
    dos2unix \
    tzdata \
    procps \
    findutils \
    coreutils \
    util-linux \
    nfs-common \
    netcat-openbsd \
    iputils-ping \
    telnet \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Verify required tools (fail build if missing)
# v3.15 adds flock (util-linux) — the Deployment cron loop's overlap guard (§8.7)
# and cksum (coreutils) — the verify slice hash (§8.10).
RUN command -v rsync && command -v curl && command -v wget \
    && command -v nc && command -v bash && command -v tini \
    && command -v dos2unix && command -v xargs \
    && command -v flock && command -v cksum

RUN mkdir -p /userapp/scripts /userapp/config /mnt/nas-target

COPY nas-sync-client.sh         /userapp/scripts/
COPY nas-sync-parallel.sh       /userapp/scripts/
COPY nas-sync-incremental.sh    /userapp/scripts/
COPY nas-sync-verify.sh         /userapp/scripts/
COPY dispatch-sync.sh           /userapp/scripts/
COPY run-with-sidecar-quit.sh   /userapp/scripts/
COPY entrypoint-deployment.sh   /userapp/scripts/

# CRLF-safe: strip carriage returns, set executable
RUN dos2unix /userapp/scripts/*.sh \
    && chmod +x /userapp/scripts/*.sh

# Fail build if any CRLF remains in any script
RUN for f in /userapp/scripts/*.sh; do \
        if head -1 "$f" | grep -q $'\r'; then \
            echo "ERROR: CRLF detected in $f" && exit 1; \
        fi; \
    done && echo "All scripts verified LF-clean"

ENV TZ=Asia/Taipei
ENV REMOTE_HOST=nas-sync.cluster-b.example.com
ENV REMOTE_PORT=8787
ENV REMOTE_MODULE=nas-data
ENV REMOTE_USER=syncuser
ENV LOCAL_NAS_PATH=/mnt/nas-target
ENV SYNC_DIRECTION=pull
ENV SYNC_MODE=standard
ENV RSYNC_TIMEOUT=14400
ENV RSYNC_PASSWORD_FILE=/userapp/config/rsync.password
ENV EXCLUDE_FILE=/userapp/config/rsync-exclude.txt
ENV CHECK_CONNECTIVITY=true
ENV CRON_SCHEDULE="0 */2 * * *"
ENV PARALLEL_WORKERS=6
ENV ISTIO_ADMIN_HOST=127.0.0.1
ENV ISTIO_ADMIN_PORT=15020
ENV SIDECAR_QUIT_ENABLED=true
ENV SIDECAR_QUIT_TIMEOUT=10
# v3.15 defaults
ENV PREFLIGHT_RETRIES=10
ENV PREFLIGHT_WAIT=6
ENV MANIFEST_MAX_AGE=86400
ENV CHUNK_MAX_AGE=86400
ENV STATUS_ENABLED=true
ENV VERIFY_MODE=meta
ENV VERIFY_SLICES=13
ENV VERIFY_FAIL_THRESHOLD=0

# Default ENTRYPOINT = CronJob wrapper.
# Deployment overrides command to use entrypoint-deployment.sh.
ENTRYPOINT ["tini", "-g", "--", "/userapp/scripts/run-with-sidecar-quit.sh"]
```

### 8.9 Build & Push

```bash
cd cluster-a/scripts
# Clean local CRLF first
sed -i 's/\r$//' *.sh 2>/dev/null || true

docker build -t ${REGISTRY}/nas-sync-client:3.15 .
docker push ${REGISTRY}/nas-sync-client:3.15

# Sanity check
docker run --rm ${REGISTRY}/nas-sync-client:3.15 sh -c \
  "ls /userapp/scripts/ && which curl wget nc bash tini xargs flock && echo OK"
```

### 8.10 File: `cluster-a/scripts/nas-sync-verify.sh` (v3.15)

> Write this file **before** running §8.9 — it is in the Dockerfile's COPY list (§8.8).
> Section order is kept stable from v3.14; build order is §8.10 then §8.9.
>
> **Drift detection, not repair.** Runs rsync with `--dry-run`, so it never transfers and
> never deletes. It counts what *would* change and exits nonzero when that exceeds
> `VERIFY_FAIL_THRESHOLD`, which makes the Job show `Failed` — drift becomes visible instead
> of silent. Repair is the reconcile's job (§9A.4). This is the direct control for everything
> in §12.1 that mtime-based incremental sync cannot see.

```bash
#!/bin/bash
#############################################
# NAS Sync — VERIFY mode (v3.15)
# Drift detection. --dry-run ONLY: transfers
# nothing, deletes nothing.
#   VERIFY_MODE=meta      size+mtime, whole tree (default)
#   VERIFY_MODE=checksum  byte compare, rotating slice
#   VERIFY_MODE=both      meta, then the checksum slice
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
PREFLIGHT_RETRIES="${PREFLIGHT_RETRIES:-10}"
PREFLIGHT_WAIT="${PREFLIGHT_WAIT:-6}"

VERIFY_MODE="${VERIFY_MODE:-meta}"
# Tier 2 reads every byte of the slice on BOTH sides. VERIFY_SLICES=13 means each run
# covers ~1/13 of the tree; full byte coverage takes 13 runs (weekly => ~1 quarter).
VERIFY_SLICES="${VERIFY_SLICES:-13}"
VERIFY_FAIL_THRESHOLD="${VERIFY_FAIL_THRESHOLD:-0}"

REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"
WORK_DIR="/tmp/nas-sync-verify.$$"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

wait_for_remote() {
    local i=1
    while [ "$i" -le "$PREFLIGHT_RETRIES" ]; do
        nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null && return 0
        log "Remote not reachable yet (attempt ${i}/${PREFLIGHT_RETRIES})"
        sleep "$PREFLIGHT_WAIT"
        i=$((i+1))
    done
    return 1
}

# NOTE: no --whole-file, no --partial — this is a comparison, nothing is written.
BASE_FLAGS="-a --dry-run --itemize-changes --timeout=$RSYNC_TIMEOUT"
BASE_FLAGS="$BASE_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && BASE_FLAGS="$BASE_FLAGS --exclude-from=$EXCLUDE_FILE"

trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR" || die "Cannot create $WORK_DIR"

START=$(date +%s)
log "=== NAS VERIFY (mode=$VERIFY_MODE) client=${CLIENT_ID:-none} ==="

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
wait_for_remote || die "Remote not reachable after ${PREFLIGHT_RETRIES} attempts"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

# Count itemized lines that represent a real difference. rsync --itemize-changes emits
# 11-char change flags; '>' = would transfer, 'c' = would create. '.' lines are matches.
count_drift() { grep -cE '^(>|c)' "$1"; }

DRIFT_TOTAL=0
CHECKED_TOTAL=0

# ---- Tier 1: metadata verify (size + mtime) over the whole tree ----
if [ "$VERIFY_MODE" = "meta" ] || [ "$VERIFY_MODE" = "both" ]; then
    log "Tier 1: metadata verify (size+mtime), whole tree..."
    rsync $BASE_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" > "${WORK_DIR}/meta.out" 2>"${WORK_DIR}/meta.err"
    RC=$?
    if [ "$RC" -ne 0 ] && [ "$RC" -ne 24 ] && [ "$RC" -ne 23 ]; then
        log_error "rsync failed during metadata verify (rc=$RC)"
        sed -n '1,20p' "${WORK_DIR}/meta.err" >&2
        die "verify aborted" "$RC"
    fi
    META_DRIFT=$(count_drift "${WORK_DIR}/meta.out")
    META_CHECKED=$(wc -l < "${WORK_DIR}/meta.out" | tr -d ' ')
    log "Tier 1: drift=$META_DRIFT of $META_CHECKED entries compared"
    [ "$META_DRIFT" -gt 0 ] && { log "First differing entries:"; grep -E '^(>|c)' "${WORK_DIR}/meta.out" | head -20; }
    DRIFT_TOTAL=$(( DRIFT_TOTAL + META_DRIFT ))
    CHECKED_TOTAL=$(( CHECKED_TOTAL + META_CHECKED ))
fi

# ---- Tier 2: checksum verify over a deterministic rotating slice ----
if [ "$VERIFY_MODE" = "checksum" ] || [ "$VERIFY_MODE" = "both" ]; then
    WEEK=$(date +%V); WEEK=$((10#$WEEK))
    SLICE=$(( WEEK % VERIFY_SLICES ))
    log "Tier 2: checksum verify, slice $SLICE of $VERIFY_SLICES (week $WEEK)..."

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

    log "Tier 2: drift=$CK_DRIFT of $CK_CHECKED entries compared"
    DRIFT_TOTAL=$(( DRIFT_TOTAL + CK_DRIFT ))
    CHECKED_TOTAL=$(( CHECKED_TOTAL + CK_CHECKED ))
fi

ELAPSED=$(( $(date +%s) - START ))

# One parseable result line — grep this from logs or an external monitor.
echo "VERIFY RESULT mode=${VERIFY_MODE} drift=${DRIFT_TOTAL} checked=${CHECKED_TOTAL} elapsed=${ELAPSED}s threshold=${VERIFY_FAIL_THRESHOLD}"

if [ "$DRIFT_TOTAL" -gt "$VERIFY_FAIL_THRESHOLD" ]; then
    log_error "DRIFT DETECTED: $DRIFT_TOTAL > threshold $VERIFY_FAIL_THRESHOLD"
    log_error "Nothing was transferred (dry-run). Run the reconcile (§9A.4) to repair."
    exit 1
fi

log "=== VERIFY OK: drift=$DRIFT_TOTAL within threshold ==="
exit 0
```

> **Schedule it right after the weekly reconcile**, when the tree is at rest — expected drift
> is then ≈ 0 and any nonzero result is real. Running it *before* the reconcile just measures
> the week's normal churn.
>
> **Expect some baseline drift** from the exclude list (§9A.1). Anything excluded from the
> sync but not from verify shows up as a difference. Both use the same `EXCLUDE_FILE`, so
> they agree by default — if you diverge them, raise `VERIFY_FAIL_THRESHOLD` accordingly.

---

## 9. Step 6A — Cluster A: CronJob Deployment

> Use for scheduled syncs. Set `SYNC_MODE` to `standard`, `parallel`, or `incremental`.

### 9A.1 Shared resources (namespace, target PV+PVC, configmap-exclude, secret)

```yaml
# cluster-a/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ea-pmc
  labels:
    app: nas-sync
---
# cluster-a/nas-target-pv.yaml — NFS-backed PersistentVolume for the TARGET (NAS A).
# This is the storage the client WRITES into. It is a static (pre-provisioned) NFS
# volume — no dynamic provisioner is involved. PV objects are cluster-scoped (NO namespace).
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nas-a-target-pv
  labels:
    app: nas-sync
    role: target
spec:
  capacity:
    storage: 100Ti                 # ◄ MODIFY — nominal only; NFS ignores it, but K8s
                                   #   requires a value. Set ≥ your real NAS A size.
  accessModes: [ReadWriteMany]     # NFS supports RWX; lets parallel/extra pods share it
  persistentVolumeReclaimPolicy: Retain   # NEVER reclaim/delete NAS data if the PVC is removed
  storageClassName: ""             # "" = static binding; do NOT use a dynamic StorageClass here
  mountOptions:                    # optional — tune/remove to match NAS A's NFS server
    - hard
    - nfsvers=4.1                  # ◄ MODIFY to 3 if NAS A only serves NFSv3
    - timeo=600
    - retrans=2
    - noatime
  nfs:
    server: "10.19.192.228"        # ◄ MODIFY — NAS A IP
    path: "/srv/nfs/data"          # ◄ MODIFY — NAS A export path
    readOnly: false                # target is written by the rsync pull (NOT read-only)
---
# cluster-a/nas-target-pvc.yaml — claim that binds 1:1 to the PV above.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nas-a-target-pvc
  namespace: ea-pmc
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""             # "" + volumeName below = bind to the static PV,
  volumeName: nas-a-target-pv      #   never the cluster's default StorageClass
  resources:
    requests:
      storage: 100Ti               # ◄ MODIFY — must be ≤ the PV capacity above
---
# cluster-a/configmap-exclude.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rsync-exclude-config
  namespace: ea-pmc
data:
  rsync-exclude.txt: |
    # --- NAS-internal directories: never real data ---
    .snapshot/
    .snapshots/
    .zfs/
    @Recently-Snapshot/
    @Recycle/
    #recycle/
    @eaDir/
    @tmp/
    System Volume Information/
    $RECYCLE.BIN/
    # --- Sync machinery (see the notes below) ---
    .rsync-partial/
    .nas-sync-state/
    .nas-sync-status/
    # --- OPINIONATED: these discard REAL source data. Review before deploying. ---
    *.tmp
    *.bak
    .DS_Store
    Thumbs.db
    .git/
---
# cluster-a/secret-password.yaml
apiVersion: v1
kind: Secret
metadata:
  name: rsync-password
  namespace: ea-pmc
type: Opaque
stringData:
  rsync.password: "YourSecurePassword123!"
```

> **`.nas-sync-state/` is client-side only.** It excludes the source NAS sync-state
> (manifests + chunk lists) from being copied to NAS A by `standard`/`parallel`/full syncs.
> Incremental mode still fetches the manifest from it explicitly (that fetch does not
> use `--exclude-from`), so this MUST stay out of the rsyncd server `exclude =` (§5.2),
> or the manifest fetch fails and incremental silently degrades to a full sync.
> The same applies to the chunk lists fetched by `parallel` mode (§8.3).
>
> **`.nas-sync-status/` (v3.15)** is written on the *target* NAS by `dispatch-sync.sh` (§8.5).
> Excluding it keeps it out of any push-direction sync and out of verify comparisons.
>
> **⚠ The last group discards real source data.** `*.tmp`, `*.bak`, `.git/`, `Thumbs.db` and
> `.DS_Store` are sensible for a *backup*, but this is a *replication* target: if NAS B
> legitimately holds files matching these patterns, NAS A will never receive them, and their
> absence is indistinguishable from a sync failure when someone goes looking. Decide
> deliberately. Whatever you choose, `SYNC_MODE=verify` (§8.10) uses the **same**
> `EXCLUDE_FILE`, so verify and sync agree and excluded files do not register as drift.

### 9A.2 File: `cluster-a/cronjob-client.yaml`

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nas-sync-client
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: client
spec:
  schedule: "0 */2 * * *"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    metadata:
      labels:
        app: nas-sync
        role: client
    spec:
      activeDeadlineSeconds: 86400
      backoffLimit: 2
      template:
        metadata:
          labels:
            app: nas-sync
            role: client
          # Sidecar likely force-injected; wrapper quits it after sync
          annotations:
            # v3.15 — REQUIRED. Without this the app container starts alongside istio-proxy
            # and its first `nc -z` to the gateway fails while the proxy is still loading
            # config: the Job dies with a false "Remote not reachable" and backoffLimit
            # re-runs the whole sync. The scripts also retry (PREFLIGHT_RETRIES, §8.2), so
            # the two together cover clusters where this annotation is disallowed by policy.
            proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
        spec:
          containers:
            - name: nas-sync-client
              image: your-registry.example.com/nas-sync-client:3.15   # ◄ MODIFY
              imagePullPolicy: Always
              # Default ENTRYPOINT = wrapper (runs dispatch → quits sidecar)
              env:
                - name: TZ
                  value: "Asia/Taipei"
                # ===== SELECT SYNC MODE HERE =====
                - name: SYNC_MODE
                  value: "incremental"          # ◄ standard | parallel | incremental
                - name: CLIENT_ID
                  value: "nas-a"                 # ◄ MODIFY — must match a registry line (§6.2); used by incremental
                - name: PARALLEL_WORKERS
                  value: "6"                     # used if SYNC_MODE=parallel
                # =================================
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
                  memory: "4Gi"                  # more for parallel/large file lists
                  cpu: "4000m"                   # 4 cores for parallel workers
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
kubectl config use-context cluster-a
kubectl apply -f cluster-a/namespace.yaml
kubectl apply -f cluster-a/nas-target-pv.yaml      # cluster-scoped PV → NAS A
kubectl apply -f cluster-a/nas-target-pvc.yaml     # binds nas-a-target-pvc to the PV
kubectl apply -f cluster-a/configmap-exclude.yaml
kubectl apply -f cluster-a/secret-password.yaml
kubectl apply -f cluster-a/cronjob-client.yaml
# Confirm the claim is Bound (not Pending) before running a sync:
kubectl get pvc nas-a-target-pvc -n ea-pmc
```

---

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

2. **Deploy this target's shared resources** — copy and adapt the §9A.1 manifests, pointing the
   PV/PVC at THIS target's NAS (its IP/export/size). Keep namespace `ea-pmc`.

3. **Bootstrap with a full seed (one-time)** — a lookback manifest never lists the whole
   dataset, so a brand-new target must be seeded first. Copy §10's
   `cluster-a/deployment-client.yaml` to `cluster-c/deployment-client.yaml`, set
   `SYNC_MODE=parallel` (no time limit) and `CLIENT_ID=nas-c`; let it finish, then delete it:
   ```bash
   # Copy + adapt §10's cluster-a/deployment-client.yaml → cluster-c/deployment-client.yaml
   # (SYNC_MODE=parallel, CLIENT_ID=nas-c, new cluster's PVC name), then:
   kubectl --context cluster-c apply -f cluster-c/deployment-client.yaml
   # …wait for the initial bulk sync to complete in logs…
   kubectl --context cluster-c delete -f cluster-c/deployment-client.yaml
   ```

4. **Switch to routine incremental** — deploy the §9A.2 CronJob with
   `SYNC_MODE=incremental` and `CLIENT_ID=nas-c`, scheduled AFTER the generator
   (the generator runs at `50 */2 * * *`; a client at `0 */2 * * *` pulls 10 min later).

5. **Add the weekly reconcile** — a second CronJob with `SYNC_MODE=parallel` (e.g.
   `0 2 * * 0`) and the same `CLIENT_ID`, per §12. This backstops any change older than
   the client's lookback window.

> `REMOTE_HOST` for every target is the **same** source — Cluster B's Istio external IP
> (`ISTIO_EXTERNAL_IP_HERE`). Targets differ only by `CLIENT_ID`, their local NAS PV/PVC,
> and their registry lookback. The source rsync daemon and generator are shared, unchanged.

---

### 9A.4 File: `cluster-a/cronjob-reconcile.yaml` (v3.15) — **required**

> **This is not optional.** `incremental` mode cannot see renames, new empty directories,
> directory metadata changes, or content edited with its mtime preserved (§12.1). The weekly
> `parallel` reconcile is the only thing that repairs them. v3.14 described this as "copy the
> client CronJob and change three fields", which meant it was routinely not deployed — it is
> now a real manifest.
>
> Identical to §9A.2 except for the four marked fields. Deploy **one per target**, and
> **stagger the schedules** across targets (§S5 in the runbook) so N full walks do not hit
> the source NAS at once.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nas-sync-reconcile              # ◄ differs from nas-sync-client
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: reconcile
spec:
  schedule: "0 2 * * 0"                 # ◄ Sunday 02:00 — stagger per target
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 3600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    metadata:
      labels:
        app: nas-sync
        role: reconcile
    spec:
      # A full reconcile of ~7.4M folders can run for many hours. Keep this comfortably
      # above the observed runtime or Kubernetes kills a healthy job mid-transfer.
      activeDeadlineSeconds: 172800     # 48h
      backoffLimit: 1
      template:
        metadata:
          labels:
            app: nas-sync
            role: reconcile
          annotations:
            proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
        spec:
          containers:
            - name: nas-sync-client
              image: your-registry.example.com/nas-sync-client:3.15   # ◄ MODIFY
              imagePullPolicy: Always
              env:
                - name: TZ
                  value: "Asia/Taipei"
                - name: SYNC_MODE
                  value: "parallel"              # ◄ full pass, uses chunks if fresh (§8.3)
                - name: CLIENT_ID
                  value: "nas-a"                 # ◄ MODIFY — same id as this target's client
                - name: PARALLEL_WORKERS
                  value: "6"                     # ◄ must fit the CPU limit below
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
                  memory: "1Gi"
                  cpu: "1000m"
                limits:
                  memory: "8Gi"
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

### 9A.5 File: `cluster-a/cronjob-verify.yaml` (v3.15)

> Drift detection (§8.10). Transfers nothing. Schedule it **after** the reconcile has
> finished, so the tree is at rest and any drift it reports is real rather than the week's
> normal churn. A nonzero drift count fails the Job, which is the point — it turns silent
> divergence into something `kubectl get jobs` shows you.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nas-sync-verify
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: verify
spec:
  schedule: "0 12 1 * *"                # ◄ monthly, 1st at 12:00 (after Sunday's reconcile)
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 3600
  successfulJobsHistoryLimit: 6         # keep a longer drift history than a sync job
  failedJobsHistoryLimit: 6
  jobTemplate:
    metadata:
      labels:
        app: nas-sync
        role: verify
    spec:
      activeDeadlineSeconds: 172800     # 48h — a full metadata walk is not fast
      backoffLimit: 0                   # a drift failure is a RESULT, not a flake: never retry
      template:
        metadata:
          labels:
            app: nas-sync
            role: verify
          annotations:
            proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
        spec:
          containers:
            - name: nas-sync-client
              image: your-registry.example.com/nas-sync-client:3.15   # ◄ MODIFY
              imagePullPolicy: Always
              env:
                - name: TZ
                  value: "Asia/Taipei"
                - name: SYNC_MODE
                  value: "verify"
                - name: VERIFY_MODE
                  value: "meta"                  # ◄ meta | checksum | both
                - name: VERIFY_SLICES
                  value: "13"                    # checksum tier: 1/13 of the tree per run
                - name: VERIFY_FAIL_THRESHOLD
                  value: "0"                     # ◄ raise if a known baseline drift exists
                - name: CLIENT_ID
                  value: "nas-a"                 # ◄ MODIFY — labels the status file only
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
                  memory: "1Gi"
                  cpu: "500m"
                limits:
                  memory: "8Gi"          # a whole-tree file list is held in memory
                  cpu: "2000m"
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
kubectl apply -f cluster-a/cronjob-verify.yaml

# Read the result of the last run:
kubectl logs -n ea-pmc -l role=verify --tail=200 | grep 'VERIFY RESULT'
```

---

## 10. Step 6B — Cluster A: Deployment (long-running)

> Use for the initial multi-day bulk sync (no 86400s limit), or as a permanent always-on alternative. Overrides ENTRYPOINT to use the deployment entry.

### 10B.1 File: `cluster-a/deployment-client.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nas-sync-client-deploy
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: client
    mode: deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nas-sync
      role: client
      mode: deployment
  template:
    metadata:
      labels:
        app: nas-sync
        role: client
        mode: deployment
      annotations:
        # v3.15 — the initial sync starts the moment the pod boots, so it races
        # istio-proxy exactly like a Job does. See §9A.2 for the full rationale.
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      containers:
        - name: nas-sync-client
          image: your-registry.example.com/nas-sync-client:3.15   # ◄ MODIFY
          # Override ENTRYPOINT: use deployment entry (initial sync + cron loop)
          command: ["tini", "-g", "--", "/userapp/scripts/entrypoint-deployment.sh"]
          imagePullPolicy: Always
          env:
            - name: TZ
              value: "Asia/Taipei"
            - name: CRON_SCHEDULE
              value: "0 */2 * * *"
            # ===== SELECT SYNC MODE HERE =====
            - name: SYNC_MODE
              value: "standard"               # ◄ standard | parallel | incremental | verify
            - name: CLIENT_ID
              value: "nas-a"                  # ◄ MODIFY — REQUIRED for incremental.
                                              #   v3.14 omitted this: without it incremental
                                              #   silently full-syncs on every cycle (§8.7).
            - name: PARALLEL_WORKERS
              value: "6"
            # =================================
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
      restartPolicy: Always
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
# Shared resources (if not already applied from 9A.1)
kubectl apply -f cluster-a/namespace.yaml
kubectl apply -f cluster-a/nas-target-pv.yaml      # cluster-scoped PV → NAS A
kubectl apply -f cluster-a/nas-target-pvc.yaml     # binds nas-a-target-pvc to the PV
kubectl apply -f cluster-a/configmap-exclude.yaml
kubectl apply -f cluster-a/secret-password.yaml
# The deployment
kubectl apply -f cluster-a/deployment-client.yaml
```

### 10B.2 Switch Deployment → CronJob after bulk sync

```bash
kubectl logs deployment/nas-sync-client-deploy -n ea-pmc -c nas-sync-client | grep "COMPLETE"
kubectl delete deployment nas-sync-client-deploy -n ea-pmc
kubectl apply -f cluster-a/cronjob-client.yaml
```

---

## 11. Step 7 — Verify & Test

### CronJob

```bash
kubectl create job --from=cronjob/nas-sync-client test-v315 -n ea-pmc
sleep 5
POD=$(kubectl get pods -n ea-pmc -l job-name=test-v315 -o jsonpath='{.items[0].metadata.name}')

# Watch it reach Completed (not stuck)
kubectl get pod $POD -n ea-pmc -w

# Logs from main container
kubectl logs $POD -n ea-pmc -c nas-sync-client

# Confirm shebang clean (CRLF fix worked)
kubectl exec $POD -n ea-pmc -c nas-sync-client -- head -1 /userapp/scripts/dispatch-sync.sh | cat -A
# Expected: #!/bin/bash$ (no ^M)

kubectl delete job test-v315 -n ea-pmc
```

### v3.15 checks

```bash
# 1. CLIENT_ID actually reaches the sync (the v3.14 Deployment bug).
#    Incremental must NOT log "Manifest fetch failed".
kubectl logs $POD -n ea-pmc -c nas-sync-client | grep -E 'client=|Incremental:|FULL sync fallback'
#    Expected: "client=nas-a" and "Incremental: N changed files"
#    A "FULL sync fallback" line means CLIENT_ID is unset or unregistered (§13).

# 2. Status file written on the target NAS.
kubectl exec $POD -n ea-pmc -c nas-sync-client -- cat /mnt/nas-target/.nas-sync-status/last-run
kubectl exec $POD -n ea-pmc -c nas-sync-client -- cat /mnt/nas-target/.nas-sync-status/last-success
#    Expected: ts=... mode=incremental client=nas-a exit=0 elapsed=...s host=...

# 3. Verify mode — on an at-rest tree, expect drift=0 and a Completed job.
kubectl create job --from=cronjob/nas-sync-verify test-verify -n ea-pmc
kubectl wait --for=condition=complete job/test-verify -n ea-pmc --timeout=7200s
kubectl logs -n ea-pmc -l job-name=test-verify | grep 'VERIFY RESULT'
#    Expected: VERIFY RESULT mode=meta drift=0 checked=... elapsed=...s threshold=0
kubectl delete job test-verify -n ea-pmc

# 4. Verify actually DETECTS drift. Touch a file on NAS B only, then re-run:
#    expect drift >= 1 and the job to show Failed. (Reverse it afterwards by
#    running the reconcile.)

# 5. Chunked reconcile — confirm workers consume chunk files.
kubectl --context cluster-b create job --from=cronjob/nas-sync-chunks test-chunks -n ea-pmc
kubectl --context cluster-b wait --for=condition=complete job/test-chunks -n ea-pmc --timeout=7200s
kubectl create job --from=cronjob/nas-sync-reconcile test-reconcile -n ea-pmc
kubectl logs -n ea-pmc -l job-name=test-reconcile | grep -E 'Using [0-9]+ server-generated chunks|START chunk-'
#    Expected: "Using 24 server-generated chunks (age=...)" and per-chunk worker lines.

# 6. Chunk FALLBACK — the reconcile must still run if chunks are gone.
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  rm -f /mnt/nas-source/.nas-sync-state/common/chunks/chunks.meta
kubectl create job --from=cronjob/nas-sync-reconcile test-fallback -n ea-pmc
kubectl logs -n ea-pmc -l job-name=test-fallback | grep -E 'falling back to top-level split'
#    Expected: the fallback line, then a normal folder-split run.

# 7. Stale-generator guard — incremental must FAIL loudly, not silently succeed.
#    Suspend the manifest CronJob for longer than MANIFEST_MAX_AGE (default 24h),
#    then run the client: expect "Manifest is STALE" and a Failed job.
```

### Deployment

```bash
kubectl get pods -n ea-pmc -l mode=deployment
kubectl logs -f deployment/nas-sync-client-deploy -n ea-pmc -c nas-sync-client
```

### Verify No-Delete

```bash
kubectl run tmp-write --rm -it --restart=Never --image=busybox -n ea-pmc \
  --overrides='{"spec":{"volumes":[{"name":"nas","persistentVolumeClaim":{"claimName":"nas-a-target-pvc"}}],"containers":[{"name":"tmp","image":"busybox","command":["sh","-c","echo keep > /mnt/.nodelete && echo OK"],"volumeMounts":[{"name":"nas","mountPath":"/mnt"}]}]}}'

kubectl create job --from=cronjob/nas-sync-client nodelete-test -n ea-pmc
kubectl wait --for=condition=complete job/nodelete-test -n ea-pmc --timeout=600s

kubectl run tmp-read --rm -it --restart=Never --image=busybox -n ea-pmc \
  --overrides='{"spec":{"volumes":[{"name":"nas","persistentVolumeClaim":{"claimName":"nas-a-target-pvc"}}],"containers":[{"name":"tmp","image":"busybox","command":["cat","/mnt/.nodelete"],"volumeMounts":[{"name":"nas","mountPath":"/mnt"}]}]}}'
# Expected: keep
kubectl delete job nodelete-test -n ea-pmc
```

---

## 12. Choosing Sync Mode

| SYNC_MODE | When | Needs | Writes? |
|-----------|------|-------|---------|
| `standard` | Small datasets, simple, first bring-up | nothing extra | yes |
| `parallel` | Large file count; bulk seed and weekly reconcile | 4+ CPU cores, `PARALLEL_WORKERS` tuned; chunk CronJob optional (§6.3) | yes |
| `incremental` | 7.4M files, low change rate (your case) | manifest CronJob on server (Step 6) | yes |
| `verify` | Confirming the target has not drifted | nothing extra | **no — `--dry-run` only** |

**Recommended for your scale (7.4M folders, 0.17% change):**

```
Initial bulk sync:    Deployment + SYNC_MODE=parallel   (no time limit)   §10
Routine (every 2h):   CronJob    + SYNC_MODE=incremental                  §9A.2
Weekly reconcile:     CronJob    + SYNC_MODE=parallel   (Sun 02:00)       §9A.4  ← REQUIRED
Monthly verify:       CronJob    + SYNC_MODE=verify     (1st, 12:00)      §9A.5
```

All four are shipped manifests. The reconcile is **required**, not a nicety — §12.1 explains
what breaks without it.

**Change mode without rebuilding:**

```bash
kubectl patch cronjob nas-sync-client -n ea-pmc --type='json' \
  -p='[{"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/env/1/value","value":"parallel"}]'
# (adjust env index to your SYNC_MODE position)
# Or simply: kubectl edit cronjob nas-sync-client -n ea-pmc
```

### 12.1 What incremental mode cannot see

`incremental` transfers exactly the paths in the server manifest, and that manifest is
`find -type f -o -type l` filtered by mtime. Everything below is therefore **invisible to it**
and is repaired only by the weekly `parallel` reconcile (§9A.4).

| Change on the source | Why the manifest misses it | State of the target until the reconcile |
|---|---|---|
| **File moved or renamed** | `mv` inside a filesystem preserves the file's mtime, so the new path never enters the manifest | New path absent. And because `--delete` is banned, the old path stays — the target now holds a **duplicate**. |
| **New empty directory** | Only files and symlinks are listed | Directory absent |
| **Directory mode / ownership change** | Directories are never listed | Old metadata retained |
| **Content changed, mtime preserved** (`touch -r`, some restore tools) | No metadata change to detect | Stale content — invisible to `verify` in `meta` mode too; needs `VERIFY_MODE=checksum` |
| **Silent corruption on either side** | No metadata change | Same — checksum tier only |
| **Change older than this client's `lookback_hours`** | Outside the window (e.g. the client was down longer than its lookback) | Missing until the reconcile; see runbook S8 |

**The orphan-duplicate case is permanent.** No sync mode removes the copy left at the old path,
because deletions never propagate — that is deliberate policy, not a bug. Over months of
reorganisation the target accumulates these. If that matters, list them with a `--dry-run`
comparison and delete them by hand after review; never add `--delete`.

**How the three controls line up:**

| Control | Catches | Cost |
|---|---|---|
| `incremental`, every 2h | New and modified files | Cheap — one server walk, transfer only the diff |
| `parallel` reconcile, weekly | Everything in the table above | One paired full walk |
| `verify`, monthly | Tells you whether the two above are actually working | One paired walk, transfers nothing |

Drop the reconcile and the first row silently becomes your whole strategy. Drop verify and you
have no evidence any of it works.

---

## 13. Troubleshooting

### `tini exec ... No such file or directory`

CRLF in a script. v3.14 build strips + verifies, so rebuild fixes it:
```bash
docker run --rm ${REGISTRY}/nas-sync-client:3.15 \
  head -1 /userapp/scripts/dispatch-sync.sh | cat -A
# Must show #!/bin/bash$ not #!/bin/bash^M$
```

### Pod stuck NotReady (sidecar)

```bash
# Confirm wrapper tried to quit sidecar
kubectl logs <pod> -n ea-pmc -c nas-sync-client | grep "\[wrapper\]"
# Emergency manual quit:
kubectl exec <pod> -n ea-pmc -c istio-proxy -- curl -X POST http://127.0.0.1:15020/quitquitquit
```

### Slow sync

```bash
# Switch to incremental (if manifest job running) or parallel
kubectl edit cronjob nas-sync-client -n ea-pmc   # set SYNC_MODE
# For parallel, ensure CPU limit allows workers; tune PARALLEL_WORKERS
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

### Connection refused 8787

```
1. kubectl get pods -n ea-pmc -l role=server
2. kubectl exec ... -c nas-sync-server -- ss -tlnp | grep 8787
3. kubectl get endpoints nas-sync-server -n ea-pmc
4. kubectl get svc $INGRESS_SVC -n istio-system | grep 8787
5. nc -zv $ISTIO_EXTERNAL_IP 8787
```

### "Remote not reachable" but the remote is healthy

Almost always the Istio sidecar-startup race: the app container ran `nc` before
`istio-proxy` finished loading configuration.

```bash
# Did it retry (v3.15) or die on the first attempt (v3.14 behavior)?
kubectl logs <pod> -n ea-pmc -c nas-sync-client | grep 'sidecar may still be starting'

# Is the proxy-start gate actually on the pod?
kubectl get pod <pod> -n ea-pmc -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep proxy.istio.io
# Expected: {"holdApplicationUntilProxyStarts": true}
```

Fix: apply the §9A.2 annotation. If cluster policy strips it, raise `PREFLIGHT_RETRIES` /
`PREFLIGHT_WAIT` instead (defaults 10 × 6s = one minute of tolerance).

### Job shows Failed but the sync log looks fine

Check the rsync return code on the COMPLETE line:

```bash
kubectl logs <pod> -n ea-pmc -c nas-sync-client | tail -3
# === COMPLETE: rsync_rc=24 exit=0, 3812s ===
```

`rsync_rc=24` ("some files vanished during transfer") and `23` are **normal** on a live
source and v3.15 maps them to exit 0. If you see `exit=` non-zero with a different code,
that is a real failure — look further up the log. rc=23 with many entries usually means
permission problems reading the source.

### Drift detected (verify job Failed)

```bash
kubectl logs -n ea-pmc -l role=verify --tail=300 | grep -E 'VERIFY RESULT|^(>|c)' | head -30
```

`VERIFY RESULT ... drift=N` with N > threshold. Nothing was transferred — verify is
`--dry-run` only. What to do:

1. **Is it real drift or excluded files?** Verify uses the same `EXCLUDE_FILE` as the sync,
   so excluded paths should not appear. If they do, the two configs have diverged (§9A.1).
2. **Repair it:** run the reconcile — `kubectl create job --from=cronjob/nas-sync-reconcile
   repair-$(date +%s) -n ea-pmc` — then re-run verify to confirm drift returns to 0.
3. **Persistent drift after a reconcile** means something the reconcile also cannot fix:
   most often files excluded on one side only, or a permissions problem on NAS A preventing
   writes. Check `last-run` vs `last-success` (below).
4. **Expected small baseline?** Set `VERIFY_FAIL_THRESHOLD` to just above it rather than
   ignoring failures — an ignored red job is the same as no monitoring.

### Is the sync even running? (status file)

```bash
# From any pod with the target PVC mounted:
kubectl exec <any-pod> -n ea-pmc -c nas-sync-client -- \
  sh -c 'cat /mnt/nas-target/.nas-sync-status/last-run; cat /mnt/nas-target/.nas-sync-status/last-success'
```

- `last-success` older than **2× the CronJob interval** → investigate.
- `last-run` newer than `last-success` → the most recent attempt failed; its `exit=` field
  names the code.
- Neither file exists → no v3.15 run has completed on this target, or `STATUS_ENABLED=false`,
  or the target NAS is not writable (which would also break the sync itself).

### Chunks stale / reconcile fell back to the top-level split

```bash
kubectl logs -n ea-pmc -l role=reconcile --tail=100 | grep -E 'chunks|falling back'
```

Messages and causes:

| Log line | Cause | Fix |
|---|---|---|
| `No chunk lists available (rc=…)` | Chunk CronJob never ran, or `.nas-sync-state/common/chunks/` unreadable | Run §6.3 job; confirm the source mount is `readOnly: false` |
| `Chunks are stale (age=… > …)` | Chunk job failed the last N weeks | Check `kubectl --context cluster-b get jobs -l role=chunks` |
| `chunks.meta present but no chunk-*.txt` | Chunk job was interrupted mid-publish | Re-run it; the atomic swap means the next run self-heals |

None of these break the reconcile — it uses the v3.14 top-level split and completes. They
only cost you the balanced-worker speedup.

### Incremental: "Manifest is STALE"

The generator CronJob on Cluster B has stopped running. v3.15 fails the client job on
purpose here: continuing would re-sync an old manifest and report success while every new
change goes unseen.

```bash
kubectl --context cluster-b get cronjob nas-sync-manifest -n ea-pmc
kubectl --context cluster-b get jobs -n ea-pmc -l role=manifest --sort-by=.metadata.creationTimestamp | tail -5
kubectl --context cluster-b logs job/<latest-manifest-job> -n ea-pmc
```

Common causes: source NFS mount became read-only, the registry ConfigMap is malformed
(`ERROR: no valid clients in registry`), or the walk now exceeds `activeDeadlineSeconds`.
Fix the generator, then the next client run proceeds normally. `MANIFEST_MAX_AGE` (default
86400s) tunes the tolerance.

---

## 14. File Checklist

### Cluster B (Server)

```
cluster-b/
├── namespace.yaml                  # 5.1
├── configmap-rsyncd.yaml           # 5.2  (reverse lookup = no)
├── secret-password.yaml            # 5.3
├── deployment-server.yaml          # 5.4  ← MODIFY registry, NAS IP
├── service.yaml                    # 5.5
├── gateway.yaml                    # 5.6  ← MODIFY selector
├── virtualservice.yaml             # 5.7
├── cronjob-manifests.yaml          # 6.1  (incremental only: registry ConfigMap + CronJob)
├── cronjob-chunks.yaml             # 6.3  (v3.15, optional: chunked reconcile)
└── scripts/
    ├── Dockerfile                  # 4.4  (CRLF-safe)
    ├── entrypoint.sh              # 4.2
    ├── generate-manifests.sh      # 4.3  (incremental only: multi-client fan-out)
    └── generate-chunks.sh         # 4.6  (v3.15, optional: equal-count chunk lists)

+ Patch non-route ingressgateway port 8787 (5.8)
```

### Cluster A (Client) — both k8s types share one image

```
cluster-a/
├── namespace.yaml                  # 9A.1
├── nas-target-pv.yaml              # 9A.1  ← NFS PV → NAS A   (MODIFY IP/path/size)
├── nas-target-pvc.yaml             # 9A.1  ← binds nas-a-target-pvc to the PV
├── configmap-exclude.yaml          # 9A.1
├── secret-password.yaml            # 9A.1
├── cronjob-client.yaml             # 9A.2  ← k8s type 1: CronJob (routine incremental)
├── cronjob-reconcile.yaml          # 9A.4  ← v3.15, REQUIRED weekly parallel reconcile
├── cronjob-verify.yaml             # 9A.5  ← v3.15, monthly drift detection
├── deployment-client.yaml          # 10B.1 ← k8s type 2: Deployment (bulk seed)
└── scripts/
    ├── Dockerfile                  # 8.8  (CRLF-safe, all scripts)
    ├── nas-sync-client.sh         # 8.2  (standard)
    ├── nas-sync-parallel.sh       # 8.3  (parallel, chunked + fallback)
    ├── nas-sync-incremental.sh    # 8.4  (incremental)
    ├── nas-sync-verify.sh         # 8.10 (v3.15, verify — dry-run only)
    ├── dispatch-sync.sh           # 8.5  (mode selector + status file)
    ├── run-with-sidecar-quit.sh   # 8.6  (CronJob wrapper)
    └── entrypoint-deployment.sh   # 8.7  (Deployment entry)
```

### Deploy Order

```
1. Build & push server image v3.15            (Step 1: write §4.2/§4.3/§4.6, then §4.5)
2. Deploy Cluster B server + patch GW         (Step 2)
3. (incremental only) Deploy registry + manifest CronJob (Step 3 / §6.2)
3b.(chunked reconcile) Deploy chunk CronJob   (§6.3)
4. Verify Cluster B                           (Step 4)
5. Build & push client image v3.15            (Step 5: write §8.2–§8.7 + §8.10, then §8.9)
6. Deploy Cluster A shared resources          (9A.1)
7. Choose k8s type:
   • CronJob    → cluster-a/cronjob-client.yaml    (Step 6A)
   • Deployment → cluster-a/deployment-client.yaml (Step 6B)
   Set SYNC_MODE in whichever you deploy.
8. Deploy the reconcile CronJob               (9A.4)  ← REQUIRED, see §12.1
9. Deploy the verify CronJob                  (9A.5)
10. Verify & test                             (Step 7)
11.(multi-target) Repeat 6–10 per extra target, distinct CLIENT_ID  (§9A.3)
```

> Ordered procedures for every operational situation — greenfield, bulk seed, onboarding a
> target while others are live, outage recovery, retirement, upgrade, triage — are in
> `docs/nas-sync-operations-runbook.md`.

---

## What This Consolidates

| Capability | Source Version | Status in v3.15 |
|-----------|----------------|-----------------|
| Port 8787 | v3.4 | ✓ |
| No-delete (keep target-only files) | v3.5 | ✓ |
| Console-only logging | v3.6 | ✓ |
| CronJob k8s type | v3.7 | ✓ (Step 6A) |
| set -e / clean exit / Deployment option | v3.8 | ✓ (Step 6B) |
| No chmod on read-only mounts | v3.9 | ✓ |
| Istio sidecar handling | v3.10 | ✓ |
| Wrapper + 4-method sidecar quit | v3.11 | ✓ (8.6) |
| CRLF-safe build (dos2unix + verify) | v3.12 | ✓ (4.4, 8.8) |
| reverse lookup = no (127.0.0.6 fix) | (DNS debug) | ✓ (5.2) |
| Parallel walk speedup | (speedup doc) | ✓ (8.3, SYNC_MODE=parallel) |
| Incremental change-list speedup | (speedup doc) | ✓ (8.4 + Step 6, SYNC_MODE=incremental) |
| Both k8s types in deployment YAMLs | (this request) | ✓ (Step 6A + 6B) |
| Explicit target NFS PV+PVC | (this request) | ✓ (9A.1) |
| Manifest state on source NAS (no PVC) | v3.13 | ✓ (§6) |
| Single-target incremental (one marker) | v3.13 | superseded by multi-target |
| Multi-target: per-client manifests | v3.14 | ✓ (§4.3, §6.1, §8.4) |
| Stateless lookback window (no markers) | v3.14 | ✓ (§4.3, §6.2) |
| Single-walk fan-out generator | v3.14 | ✓ (§4.3) |
| Client registry ConfigMap | v3.14 | ✓ (§6.2) |
| Per-target deploy walkthrough | v3.14 | ✓ (§9A.3) |
| `SYNC_MODE=verify` drift detection (dry-run) | v3.15 | ✓ (§8.10, §9A.5) |
| Chunked parallel reconcile + fallback | v3.15 | ✓ (§4.6, §6.3, §8.3) |
| Sync status file on target NAS | v3.15 | ✓ (§8.5) |
| Weekly reconcile as a shipped manifest | v3.15 | ✓ (§9A.4) — required, see §12.1 |
| `SYNC_ID` per-target markers (proposed) | v3.15 spec | superseded by v3.14 registry — see the review, §5 |
| **Defect fixes (v3.15)** | | |
| `CLIENT_ID` reaches Deployment cron env | v3.15 | ✓ (§8.7, §10B.1) — was a permanent full sync |
| Manifest fetch trusts exit code, unique tmp | v3.15 | ✓ (§8.4) — was a silent skipped window |
| Stale-generator guard (`MANIFEST_MAX_AGE`) | v3.15 | ✓ (§8.4) |
| `.snapshot` pruned by name at all depths | v3.15 | ✓ (§4.3, §4.6) |
| Symlinks included in the manifest | v3.15 | ✓ (§4.3) |
| `--partial-dir` (no truncated files on target) | v3.15 | ✓ (§8.2–§8.4) |
| Istio proxy-start gate + preflight retry | v3.15 | ✓ (§9A.2, §9A.4, §9A.5, §10B.1, §8.2) |
| rsync rc 23/24 tolerated | v3.15 | ✓ (§8.2–§8.4) |
| `flock` overlap guard in Deployment cron | v3.15 | ✓ (§8.7) |
| Cron registered once (not twice) | v3.15 | ✓ (§8.7) |
| Per-worker failure tally in parallel mode | v3.15 | ✓ (§8.3) |

Full rationale, evidence and failure scenarios for every v3.15 row:
`docs/reviews/2026-07-22-nas-sync-architecture-review.md`.

---

## Appendix: Migrating v3.13 (single-target) → v3.14 (multi-target)

The existing single client keeps working; cut it over to the per-client model:

1. **Rebuild the server image** (`:3.15`) so `generate-manifests.sh` replaces the old
   `generate-manifest.sh` (§4.3–§4.5), and rebuild/redeploy nothing else on the source
   except the manifest CronJob.
2. **Create the registry** with your existing client as `nas-a` (§6.2). Pick its lookback
   from its current schedule (2h CronJob → `6`).
3. **Replace** `cronjob-manifest.yaml` (the old v3.13 single-client file) with
   `cronjob-manifests.yaml` (§6.1) and apply.
   The generator now writes `.nas-sync-state/clients/nas-a/sync-manifest.txt`.
4. **Add `CLIENT_ID=nas-a`** to the existing client CronJob (§9A.2) and apply. It now
   fetches the per-client path instead of the old global `.nas-sync-state/sync-manifest.txt`.
5. **Decommission the old global manifest** — once the client logs the per-client path,
   delete the stale `.nas-sync-state/sync-manifest.txt` and `last-sync-marker` on the
   source NAS (the v3.14 model is stateless and no longer uses a marker).
6. **Add further targets** per §9A.3.

> No data re-sync is required for the existing target: its files already match. The first
> v3.14 incremental run simply pulls whatever changed within `nas-a`'s lookback window.

### Also required when coming from v3.14 → v3.15

The four steps above cover the v3.13 → v3.14 state change. Moving v3.14 → v3.15 changes no
state at all — it is a rebuild plus three new manifests:

1. **Add the new scripts** `generate-chunks.sh` (§4.6) and `nas-sync-verify.sh` (§8.10),
   rebuild **both** images as `:3.15` (§4.5, §8.9), and roll the server Deployment.
2. **Update the existing client CronJob** (§9A.2): new image tag and the
   `proxy.istio.io/config` annotation. Same for the Deployment (§10B.1) — and if it runs
   `incremental`, add `CLIENT_ID`, which v3.14 omitted.
3. **Deploy the reconcile** (§9A.4). If you were already running a hand-copied reconcile,
   replace it with this manifest so it stays in the checklist.
4. **Deploy verify** (§9A.5), and optionally the chunk generator (§6.3).
5. **Confirm** with §11's v3.15 checks — especially that `last-run`/`last-success` appear on
   the target NAS and that incremental no longer logs `FULL sync fallback`.

> Nothing on the source NAS needs migrating: `.nas-sync-state/clients/<id>/` is unchanged and
> `common/chunks/` is created on first use.
