# Cross-Cluster NAS Rsync — Consolidated Guide v3.13

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
│  Sync layer (chosen by SYNC_MODE env var):                               │
│   • standard     → nas-sync-client.sh                                    │
│   • parallel     → nas-sync-parallel.sh                                  │
│   • incremental  → nas-sync-incremental.sh                               │
│                                                                          │
│  All scripts: CRLF-stripped at build, LF-verified, +x                    │
└────────────────────────────────────────────────────────────────────────┘
```

Two independent choices:
- **k8s type** (CronJob vs Deployment) → how the container is scheduled/lives
- **SYNC_MODE** (standard/parallel/incremental) → which sync algorithm runs

Both combine freely. E.g. CronJob+incremental for routine, Deployment+parallel for bulk.

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
# NAS Sync Server v3.13 — Entrypoint
#############################################
set +e
RSYNC_PORT="${RSYNC_PORT:-8787}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }

log "========================================"
log "NAS Sync Server v3.13 (Cluster B)"
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

### 4.3 File: `cluster-b/scripts/generate-manifest.sh`

> Used only for `incremental` mode. Produces the changed-file list.

```bash
#!/bin/bash
#############################################
# Manifest Generator (Cluster B)
# Lists files changed since last sync for
# incremental mode (--files-from on client).
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
log "Manifest Generator v3.13"
log "  Source: $SOURCE_PATH | State: $STATE_DIR"
log "========================================"

# Capture scan start time; files changed during scan caught next run
touch "$MARKER_CANDIDATE"

if [ ! -f "$MARKER" ]; then
    log "No marker — first run. Signaling FULL_SYNC."
    echo "FULL_SYNC" > "$MANIFEST"
else
    log "Generating changed-file list (newer than marker)..."
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

### 4.4 File: `cluster-b/scripts/Dockerfile` (CRLF-safe)

```dockerfile
FROM ubuntu:24.04

LABEL version="3.13"
LABEL description="NAS Sync Server - rsync daemon + manifest (CRLF-safe)"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    rsync \
    dos2unix \
    tzdata \
    procps \
    iproute2 \
    findutils \
    nfs-common \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /mnt/nas-source

COPY entrypoint.sh /entrypoint.sh
COPY generate-manifest.sh /userapp/scripts/generate-manifest.sh

# CRLF-safe: strip carriage returns, set executable
RUN dos2unix /entrypoint.sh /userapp/scripts/generate-manifest.sh \
    && chmod +x /entrypoint.sh /userapp/scripts/generate-manifest.sh

# Fail build if any CRLF remains
RUN for f in /entrypoint.sh /userapp/scripts/generate-manifest.sh; do \
        if head -1 "$f" | grep -q $'\r'; then \
            echo "ERROR: CRLF in $f" && exit 1; \
        fi; \
    done && echo "Scripts verified LF-clean"

ENV TZ=Asia/Taipei
ENV RSYNC_PORT=8787

EXPOSE 8787

ENTRYPOINT ["/entrypoint.sh"]
```

### 4.5 Build & Push

```bash
cd cluster-b/scripts
# Clean local CRLF first (belt and suspenders)
sed -i 's/\r$//' entrypoint.sh generate-manifest.sh 2>/dev/null || true

docker build -t ${REGISTRY}/nas-sync-server:3.13 .
docker push ${REGISTRY}/nas-sync-server:3.13
```

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

> Note `reverse lookup = no` (fixes the 127.0.0.6 DNS stall) and the optional `[manifest]` module for read-only-NAS setups.

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
          image: your-registry.example.com/nas-sync-server:3.13    # ◄ MODIFY
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
              # read-write IF using incremental (manifest written into source).
              # If NAS B must be read-only, see Step 6 [manifest] module option.
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

### 6.1 cronjob-manifest.yaml

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nas-sync-manifest
  namespace: ea-pmc
  labels:
    app: nas-sync
    role: manifest
spec:
  # Run 10 min BEFORE the client incremental sync
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
            sidecar.istio.io/inject: "false"   # try; if forced, harmless here
        spec:
          containers:
            - name: manifest-gen
              image: your-registry.example.com/nas-sync-server:3.13   # ◄ reuse server image
              command: ["/bin/bash", "/userapp/scripts/generate-manifest.sh"]
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
          restartPolicy: Never
          volumes:
            - name: nas-source
              nfs:
                server: "10.90.220.155"          # ◄ MODIFY
                path: "/PMCenterData"            # ◄ MODIFY
                readOnly: false                  # REQUIRED: manifest + state are written here
```

```bash
# Only if using incremental mode:
kubectl apply -f cluster-b/cronjob-manifest.yaml
```

---

## 7. Step 4 — Cluster B: Verify

```bash
kubectl get pods -n ea-pmc -l app=nas-sync,role=server
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- ss -tlnp | grep 8787
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- rsync --list-only rsync://localhost:8787/nas-data/ | head
kubectl get svc $INGRESS_SVC -n istio-system -o jsonpath='{range .spec.ports[*]}{.name}:{.port}{"\n"}{end}' | grep 8787
nc -zv ${ISTIO_EXTERNAL_IP} 8787
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

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

# --whole-file (faster over proxy), no -v (quiet), no --delete
RSYNC_FLAGS="-a --whole-file --partial --stats --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

START=$(date +%s)
log "=== NAS SYNC (standard) ==="
log "Remote: $REMOTE_URL/ → $LOCAL_NAS_PATH"

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null || die "Remote not reachable"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

if [ "$SYNC_DIRECTION" = "pull" ]; then
    rsync $RSYNC_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
else
    rsync $RSYNC_FLAGS "${LOCAL_NAS_PATH}/" "${REMOTE_URL}/" 2>&1
fi
SYNC_EXIT=$?

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: exit=$SYNC_EXIT, ${DUR}s ==="
exit $SYNC_EXIT
```

### 8.3 File: `cluster-a/scripts/nas-sync-parallel.sh` (parallel mode)

```bash
#!/bin/bash
#############################################
# NAS Sync — PARALLEL mode
# N concurrent workers split by top-level folder
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

FOLDER_LIST="/tmp/nas-sync-folders.txt"
REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

RSYNC_FLAGS="-a --whole-file --partial --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

START=$(date +%s)
log "=== NAS SYNC (parallel, $PARALLEL_WORKERS workers) ==="

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null || die "Remote not reachable"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

log "Listing top-level folders..."
rsync --list-only --password-file="$RSYNC_PASSWORD_FILE" "${REMOTE_URL}/" 2>/dev/null \
    | awk '$1 ~ /^d/ && $NF != "." {print $NF}' > "$FOLDER_LIST"
FOLDER_COUNT=$(wc -l < "$FOLDER_LIST")
log "Found $FOLDER_COUNT top-level folders"
[ "$FOLDER_COUNT" -gt 0 ] || die "No folders found"

log "Syncing top-level loose files..."
rsync $RSYNC_FLAGS --dirs "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1 | grep -v '^$'

sync_one_folder() {
    local folder="$1"
    local s=$(date +%s)
    echo "$(date '+%H:%M:%S') [worker] START $folder"
    rsync $RSYNC_FLAGS "${REMOTE_URL}/${folder}/" "${LOCAL_NAS_PATH}/${folder}/" 2>&1 | sed "s/^/[$folder] /"
    local rc=${PIPESTATUS[0]}
    echo "$(date '+%H:%M:%S') [worker] DONE  $folder (rc=$rc, $(( $(date +%s) - s ))s)"
    return $rc
}
export -f sync_one_folder
export REMOTE_URL LOCAL_NAS_PATH RSYNC_FLAGS

cat "$FOLDER_LIST" | xargs -P "$PARALLEL_WORKERS" -I {} bash -c 'sync_one_folder "$@"' _ {}
RC=$?

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: $FOLDER_COUNT folders, ${DUR}s, rc=$RC ==="
exit $RC
```

### 8.4 File: `cluster-a/scripts/nas-sync-incremental.sh` (incremental mode)

```bash
#!/bin/bash
#############################################
# NAS Sync — INCREMENTAL mode
# Sync only changed files from server manifest
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
MANIFEST_NAME="${MANIFEST_NAME:-.nas-sync-state/sync-manifest.txt}"

MANIFEST_LOCAL="/tmp/sync-manifest.txt"
REMOTE_URL="rsync://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_MODULE}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; }
die() { log_error "$1"; exit "${2:-1}"; }

RSYNC_FLAGS="-a --whole-file --partial --timeout=$RSYNC_TIMEOUT"
RSYNC_FLAGS="$RSYNC_FLAGS --password-file=$RSYNC_PASSWORD_FILE"
[ -f "$EXCLUDE_FILE" ] && RSYNC_FLAGS="$RSYNC_FLAGS --exclude-from=$EXCLUDE_FILE"

START=$(date +%s)
log "=== NAS SYNC (incremental) ==="

[ -r "$RSYNC_PASSWORD_FILE" ] || die "Password file not readable"
nc -z -w 10 "$REMOTE_HOST" "$REMOTE_PORT" 2>/dev/null || die "Remote not reachable"
timeout 10 mountpoint -q "$LOCAL_NAS_PATH" 2>/dev/null || die "Local NAS not mounted"
log "OK Pre-flight"

log "Fetching manifest ($MANIFEST_NAME)..."
rsync -a --password-file="$RSYNC_PASSWORD_FILE" \
    "${REMOTE_URL}/${MANIFEST_NAME}" "$MANIFEST_LOCAL" 2>&1

if [ ! -f "$MANIFEST_LOCAL" ]; then
    log "Manifest fetch failed — FULL sync fallback"
    rsync $RSYNC_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
    exit $?
fi

if grep -q "^FULL_SYNC$" "$MANIFEST_LOCAL"; then
    log "FULL_SYNC signaled (first run)"
    rsync $RSYNC_FLAGS "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
    SYNC_EXIT=$?
else
    CHANGED=$(grep -vc '^$' "$MANIFEST_LOCAL")
    log "Incremental: $CHANGED changed files"
    if [ "$CHANGED" -eq 0 ]; then
        log "Nothing changed. Skipping."
        SYNC_EXIT=0
    else
        rsync $RSYNC_FLAGS --files-from="$MANIFEST_LOCAL" \
            "${REMOTE_URL}/" "${LOCAL_NAS_PATH}/" 2>&1
        SYNC_EXIT=$?
    fi
fi

DUR=$(( $(date +%s) - START ))
log "=== COMPLETE: exit=$SYNC_EXIT, ${DUR}s ==="
exit $SYNC_EXIT
```

### 8.5 File: `cluster-a/scripts/dispatch-sync.sh` (mode selector)

> Central dispatcher — picks the sync script based on `SYNC_MODE`.

```bash
#!/bin/bash
#############################################
# Dispatch — selects sync script by SYNC_MODE
#############################################
SYNC_MODE="${SYNC_MODE:-standard}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [dispatch] $1"; }

case "$SYNC_MODE" in
    parallel)
        log "Mode: parallel"
        exec /userapp/scripts/nas-sync-parallel.sh
        ;;
    incremental)
        log "Mode: incremental"
        exec /userapp/scripts/nas-sync-incremental.sh
        ;;
    standard|*)
        log "Mode: standard"
        exec /userapp/scripts/nas-sync-client.sh
        ;;
esac
```

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

log "=== NAS Sync Client v3.13 (Deployment, SYNC_MODE=${SYNC_MODE:-standard}) ==="
log "Cron: ${CRON_SCHEDULE}"

printenv | grep -E '^(REMOTE_|LOCAL_|SYNC_|RSYNC_|EXCLUDE_|CHECK_|TZ|PARALLEL_|MANIFEST_)' > /etc/environment

cat > /etc/cron.d/nas-sync << EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${CRON_SCHEDULE} root . /etc/environment && /userapp/scripts/dispatch-sync.sh > /proc/1/fd/1 2>/proc/1/fd/2
EOF
chmod 0644 /etc/cron.d/nas-sync
crontab /etc/cron.d/nas-sync
log "OK Cron configured"

log "=== INITIAL SYNC (no time limit) ==="
/userapp/scripts/dispatch-sync.sh
log "Initial sync done (exit $?). Starting cron..."

exec cron -f
```

### 8.8 File: `cluster-a/scripts/Dockerfile` (CRLF-safe, all scripts)

```dockerfile
FROM ubuntu:24.04

LABEL version="3.13"
LABEL description="NAS Sync Client - all modes, both k8s types, CRLF-safe"

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
    nfs-common \
    netcat-openbsd \
    iputils-ping \
    telnet \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Verify required tools (fail build if missing)
RUN command -v rsync && command -v curl && command -v wget \
    && command -v nc && command -v bash && command -v tini \
    && command -v dos2unix && command -v xargs

RUN mkdir -p /userapp/scripts /userapp/config /mnt/nas-target

COPY nas-sync-client.sh         /userapp/scripts/
COPY nas-sync-parallel.sh       /userapp/scripts/
COPY nas-sync-incremental.sh    /userapp/scripts/
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

# Default ENTRYPOINT = CronJob wrapper.
# Deployment overrides command to use entrypoint-deployment.sh.
ENTRYPOINT ["tini", "-g", "--", "/userapp/scripts/run-with-sidecar-quit.sh"]
```

### 8.9 Build & Push

```bash
cd cluster-a/scripts
# Clean local CRLF first
sed -i 's/\r$//' *.sh 2>/dev/null || true

docker build -t ${REGISTRY}/nas-sync-client:3.13 .
docker push ${REGISTRY}/nas-sync-client:3.13

# Sanity check
docker run --rm ${REGISTRY}/nas-sync-client:3.13 sh -c \
  "ls /userapp/scripts/ && which curl wget nc bash tini xargs && echo OK"
```

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
    .rsync-partial/
    *.tmp
    *.bak
    .DS_Store
    Thumbs.db
    .git/
    .nas-sync-state/
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
> (manifest + marker) from being copied to NAS A by `standard`/`parallel`/full syncs.
> Incremental mode still fetches the manifest from it explicitly (that fetch does not
> use `--exclude-from`), so this MUST stay out of the rsyncd server `exclude =` (§5.2),
> or the manifest fetch fails and incremental silently degrades to a full sync.

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
        spec:
          containers:
            - name: nas-sync-client
              image: your-registry.example.com/nas-sync-client:3.13   # ◄ MODIFY
              imagePullPolicy: Always
              # Default ENTRYPOINT = wrapper (runs dispatch → quits sidecar)
              env:
                - name: TZ
                  value: "Asia/Taipei"
                # ===== SELECT SYNC MODE HERE =====
                - name: SYNC_MODE
                  value: "incremental"          # ◄ standard | parallel | incremental
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
    spec:
      containers:
        - name: nas-sync-client
          image: your-registry.example.com/nas-sync-client:3.13   # ◄ MODIFY
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
              value: "standard"               # ◄ standard | parallel | incremental
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
kubectl create job --from=cronjob/nas-sync-client test-v313 -n ea-pmc
sleep 5
POD=$(kubectl get pods -n ea-pmc -l job-name=test-v313 -o jsonpath='{.items[0].metadata.name}')

# Watch it reach Completed (not stuck)
kubectl get pod $POD -n ea-pmc -w

# Logs from main container
kubectl logs $POD -n ea-pmc -c nas-sync-client

# Confirm shebang clean (CRLF fix worked)
kubectl exec $POD -n ea-pmc -c nas-sync-client -- head -1 /userapp/scripts/dispatch-sync.sh | cat -A
# Expected: #!/bin/bash$ (no ^M)

kubectl delete job test-v313 -n ea-pmc
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

| SYNC_MODE | When | Needs |
|-----------|------|-------|
| `standard` | Small datasets, simple, first bring-up | nothing extra |
| `parallel` | Large file count, no NAS change-tracking | 4+ CPU cores, `PARALLEL_WORKERS` tuned |
| `incremental` | 7.4M files, low change rate (your case) | manifest CronJob on server (Step 6) |

**Recommended for your scale (7.4M folders, 0.17% change):**

```
Routine (every 2h):   CronJob + SYNC_MODE=incremental
Weekly reconcile:     CronJob + SYNC_MODE=parallel (Sunday 2 AM)
Initial bulk sync:    Deployment + SYNC_MODE=parallel (no time limit)
```

Two CronJobs for routine + reconcile:

```bash
# Routine incremental (the cronjob-client.yaml above, SYNC_MODE=incremental)

# Weekly full reconcile — copy cronjob-client.yaml, rename, change:
#   metadata.name: nas-sync-reconcile
#   schedule: "0 2 * * 0"
#   SYNC_MODE: parallel
```

**Change mode without rebuilding:**

```bash
kubectl patch cronjob nas-sync-client -n ea-pmc --type='json' \
  -p='[{"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/env/1/value","value":"parallel"}]'
# (adjust env index to your SYNC_MODE position)
# Or simply: kubectl edit cronjob nas-sync-client -n ea-pmc
```

---

## 13. Troubleshooting

### `tini exec ... No such file or directory`

CRLF in a script. v3.13 build strips + verifies, so rebuild fixes it:
```bash
docker run --rm ${REGISTRY}/nas-sync-client:3.13 \
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

### Incremental: manifest not found

```bash
# Check manifest job ran and wrote the file
kubectl logs job/<manifest-job> -n ea-pmc
kubectl exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.nas-sync-state/
```

### Connection refused 8787

```
1. kubectl get pods -n ea-pmc -l role=server
2. kubectl exec ... -c nas-sync-server -- ss -tlnp | grep 8787
3. kubectl get endpoints nas-sync-server -n ea-pmc
4. kubectl get svc $INGRESS_SVC -n istio-system | grep 8787
5. nc -zv $ISTIO_EXTERNAL_IP 8787
```

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
├── cronjob-manifest.yaml           # 6.1  (incremental only)
└── scripts/
    ├── Dockerfile                  # 4.4  (CRLF-safe)
    ├── entrypoint.sh              # 4.2
    └── generate-manifest.sh       # 4.3  (incremental only)

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
├── cronjob-client.yaml             # 9A.2  ← k8s type 1: CronJob
├── deployment-client.yaml          # 10B.1 ← k8s type 2: Deployment
└── scripts/
    ├── Dockerfile                  # 8.8  (CRLF-safe, all scripts)
    ├── nas-sync-client.sh         # 8.2  (standard)
    ├── nas-sync-parallel.sh       # 8.3  (parallel)
    ├── nas-sync-incremental.sh    # 8.4  (incremental)
    ├── dispatch-sync.sh           # 8.5  (mode selector)
    ├── run-with-sidecar-quit.sh   # 8.6  (CronJob wrapper)
    └── entrypoint-deployment.sh   # 8.7  (Deployment entry)
```

### Deploy Order

```
1. Build & push server image v3.13           (Step 1)
2. Deploy Cluster B server + patch GW         (Step 2)
3. (incremental only) Deploy manifest CronJob (Step 3)
4. Verify Cluster B                           (Step 4)
5. Build & push client image v3.13            (Step 5)
6. Deploy Cluster A shared resources          (9A.1)
7. Choose k8s type:
   • CronJob    → cluster-a/cronjob-client.yaml    (Step 6A)
   • Deployment → cluster-a/deployment-client.yaml (Step 6B)
   Set SYNC_MODE in whichever you deploy.
8. Verify & test                              (Step 7)
```

---

## What This Consolidates

| Capability | Source Version | Status in v3.13 |
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
| Manifest state on source NAS (no PVC) | (this request) | ✓ (§6) |
