# Cross-Cluster NAS Sync — Operations Runbook

**Companion to** `cross-cluster-rsync-guide-v3.15-consolidated.md` (referred to below as
"the guide"). The guide is the **reference**: every file, every flag, why each exists. This
runbook is the **procedure**: given a situation, what do you run, in what order, and how do
you know it worked.

Every scenario links back to the guide's `§` numbers rather than duplicating its code.

---

## Scenario index

| | Situation | Go to |
|---|---|---|
| **S0** | I'm starting from nothing — what do I need first? | [S0](#s0--prerequisites--values-worksheet) |
| **S1** | Stand up the first source and first target | [S1](#s1--greenfield-first-source--first-target) |
| **S2** | Seed a large dataset for the first time | [S2](#s2--initial-bulk-seed) |
| **S3** | Bulk finished — switch to routine syncing | [S3](#s3--cut-over-bulk--routine) |
| **S4** | Add another target while existing ones keep running | [S4](#s4--onboard-an-additional-target-while-others-are-live) |
| **S5** | What should be running, and when? | [S5](#s5--steady-state) |
| **S6** | Change sync mode without rebuilding | [S6](#s6--change-sync-mode-on-a-live-object) |
| **S7** | Prove the target actually matches the source | [S7](#s7--drift-check) |
| **S8** | A target was down for a while — did we lose changes? | [S8](#s8--client-outage-recovery) |
| **S9** | The source side broke | [S9](#s9--source-side-failure) |
| **S10** | Retire a target | [S10](#s10--retire-a-target) |
| **S11** | Upgrade to a new version | [S11](#s11--version-upgrade) |
| **S12** | Something is wrong and I don't know what | [S12](#s12--triage-decision-tree) |
| **S13** | It works but it's too slow / too heavy | [S13](#s13--tuning) |
| **S14** | The source NAS is read-only | [S14](#s14--read-only-source) |

**Conventions used throughout:** namespace `ea-pmc`, port `8787`, deletions never propagate
(never add `--delete`), console-only logging. `--context cluster-b` = source side,
`--context cluster-a` = a target side. Substitute your own context names.

---

## S0 — Prerequisites & values worksheet

Do this before anything else. Most failed bring-ups trace to one of these.

**Fill in your values** (guide §3):

```
REGISTRY=your-registry.example.com        # ◄ your image registry
NAS_B_IP=10.90.220.155 ; NAS_B_PATH=/PMCenterData      # source
NAS_A_IP=10.19.192.228 ; NAS_A_PATH=/srv/nfs/data      # target
NAMESPACE=ea-pmc
INGRESS_SVC=istio-ingressgateway-nonroute
INGRESS_GW_SELECTOR=ingressgateway-nonroute
ISTIO_EXTERNAL_IP=<filled in during S1 step 3>
SYNC_PASSWORD=<generate one>
SYNC_PORT=8787
CLIENT_ID=nas-a                           # ◄ unique per target
```

**Verify each of these before proceeding:**

```bash
# 1. Source NFS export reachable from Cluster B nodes
showmount -e ${NAS_B_IP}          # must list ${NAS_B_PATH}

# 2. Target NFS export reachable AND WRITABLE from Cluster A nodes
showmount -e ${NAS_A_IP}          # must list ${NAS_A_PATH}
```

The target export is the one that bites. Confirm all four (guide §3):

- Client ACL includes the **worker nodes / pod subnet**, not just your laptop.
- Exported **`rw`**, not `ro`. A `ro` export fails with `Read-only file system` on first write.
- **UID/GID mapping works.** rsync writes as the container UID (root). Under `root_squash`
  writes land as `nobody` — that identity must be able to create and own files under the
  export, or set `anonuid`/`anongid`.
- **NFS version matches** the PV's `mountOptions` (`nfsvers=4.1` by default; change to `3`
  if the NAS only serves NFSv3, or the PV stays `Pending`).

```bash
# 3. Istio present on the source cluster, and the non-route gateway has an external IP
kubectl --context cluster-b get pods -n istio-system
kubectl --context cluster-b get svc -n istio-system | grep gateway

# 4. Registry reachable from both clusters
docker pull ${REGISTRY}/<any-existing-image>
```

**Also decide now** (changing these later is disruptive):

- **Will the source NAS export be writable?** `incremental` mode writes manifests into
  `.nas-sync-state/` on the source. If it cannot be writable, go to [S14](#s14--read-only-source).
- **`lookback_hours` per target** — pull period × 2–3, or pull period + worst tolerated
  outage. See [S13](#s13--tuning).
- **Your exclude list** — guide §9A.1 excludes `*.tmp`, `*.bak`, `.git/` by default. For a
  *replication* target that silently discards real source data. Review it deliberately.

---

## S1 — Greenfield: first source + first target

The full path from nothing to a working sync. Roughly 1–2 hours excluding the data transfer.

**Order matters:** the source must be serving before the target can pull, and the target
CronJob will fail loudly if you deploy it first.

### Phase 1 — Source cluster (Cluster B)

```bash
# 1. Write the server scripts and Dockerfile:
#      §4.2 entrypoint.sh, §4.3 generate-manifests.sh,
#      §4.6 generate-chunks.sh, §4.4 Dockerfile
#    ALL scripts must be LF-only. On Windows: sed -i 's/\r$//' *.sh
# 2. Build & push (§4.5)
cd cluster-b/scripts
docker build -t ${REGISTRY}/nas-sync-server:3.15 . && docker push ${REGISTRY}/nas-sync-server:3.15

# 3. Deploy the daemon + gateway (§5.1–§5.8)
kubectl --context cluster-b apply -f cluster-b/namespace.yaml
kubectl --context cluster-b apply -f cluster-b/configmap-rsyncd.yaml
kubectl --context cluster-b apply -f cluster-b/secret-password.yaml
kubectl --context cluster-b apply -f cluster-b/deployment-server.yaml
kubectl --context cluster-b apply -f cluster-b/service.yaml
kubectl --context cluster-b apply -f cluster-b/gateway.yaml
kubectl --context cluster-b apply -f cluster-b/virtualservice.yaml
# Patch port 8787 onto the non-route ingressgateway (§5.8) — easy to forget
```

**Done when** (guide §7):

```bash
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  rsync --list-only rsync://localhost:8787/nas-data/ | head
ISTIO_EXTERNAL_IP=$(kubectl --context cluster-b get svc $INGRESS_SVC -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
nc -zv ${ISTIO_EXTERNAL_IP} 8787        # must connect from OUTSIDE cluster B
```

Record `ISTIO_EXTERNAL_IP` — every target uses it as `REMOTE_HOST`.

### Phase 2 — Manifest generator (only if using `incremental`)

```bash
# Registry ConfigMap + generator CronJob (§6.1, §6.2). Start with one line:
#   nas-a   6
kubectl --context cluster-b apply -f cluster-b/cronjob-manifests.yaml

# Force a first run rather than waiting for the schedule:
kubectl --context cluster-b create job --from=cronjob/nas-sync-manifest bootstrap -n ea-pmc
kubectl --context cluster-b wait --for=condition=complete job/bootstrap -n ea-pmc --timeout=7200s
kubectl --context cluster-b logs job/bootstrap -n ea-pmc
```

**Done when** a manifest exists for your client:

```bash
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  sh -c 'for d in /mnt/nas-source/.nas-sync-state/clients/*/; do \
    echo "$d: $(wc -l < "$d/sync-manifest.txt" 2>/dev/null || echo MISSING) files"; done'
```

### Phase 3 — Target cluster (Cluster A)

```bash
# 1. Write the client scripts: §8.2–§8.7, §8.10, and the §8.8 Dockerfile. LF only.
# 2. Build & push (§8.9)
cd cluster-a/scripts
docker build -t ${REGISTRY}/nas-sync-client:3.15 . && docker push ${REGISTRY}/nas-sync-client:3.15

# 3. Shared resources (§9A.1)
kubectl --context cluster-a apply -f cluster-a/namespace.yaml
kubectl --context cluster-a apply -f cluster-a/nas-target-pv.yaml     # cluster-scoped
kubectl --context cluster-a apply -f cluster-a/nas-target-pvc.yaml
kubectl --context cluster-a apply -f cluster-a/configmap-exclude.yaml
kubectl --context cluster-a apply -f cluster-a/secret-password.yaml

# STOP: the claim must be Bound before any sync can work.
kubectl --context cluster-a get pvc nas-a-target-pvc -n ea-pmc
# Pending => the PV/NFS settings are wrong. Fix before continuing (see S0).
```

Now seed the data. **If the dataset is large, go to [S2](#s2--initial-bulk-seed) instead** —
`incremental` alone never seeds a full dataset, and a CronJob's `activeDeadlineSeconds` will
kill a multi-day first sync.

For a small dataset, deploy the routine CronJob directly:

```bash
kubectl --context cluster-a apply -f cluster-a/cronjob-client.yaml     # §9A.2
kubectl --context cluster-a apply -f cluster-a/cronjob-reconcile.yaml  # §9A.4 — REQUIRED
kubectl --context cluster-a apply -f cluster-a/cronjob-verify.yaml     # §9A.5
```

### Phase 4 — Prove it

```bash
kubectl --context cluster-a create job --from=cronjob/nas-sync-client test-v315 -n ea-pmc
POD=$(kubectl --context cluster-a get pods -n ea-pmc -l job-name=test-v315 -o jsonpath='{.items[0].metadata.name}')
kubectl --context cluster-a logs -f $POD -n ea-pmc -c nas-sync-client
```

**Done when all five hold:**

1. The pod reaches `Completed` — not stuck `NotReady` (that means the sidecar wasn't quit).
2. The log shows `client=nas-a` and `Incremental: N changed files` — **not**
   `FULL sync fallback` (see [S12](#s12--triage-decision-tree)).
3. `=== COMPLETE: rsync_rc=0 exit=0 ... ===`.
4. The status file exists:
   `kubectl exec $POD -n ea-pmc -c nas-sync-client -- cat /mnt/nas-target/.nas-sync-status/last-success`
5. The shebang check is clean:
   `kubectl exec $POD -n ea-pmc -c nas-sync-client -- head -1 /userapp/scripts/dispatch-sync.sh | cat -A`
   → `#!/bin/bash$`. A trailing `^M` means CRLF got in; rebuild.

```bash
kubectl --context cluster-a delete job test-v315 -n ea-pmc
```

---

## S2 — Initial bulk seed

For a first sync of a large dataset (hours to days). A CronJob is the wrong tool: it has a
deadline and it will be killed mid-transfer. Use a **Deployment** instead — it has no time
limit and does not quit the Istio sidecar.

```bash
# Copy §10B.1 deployment-client.yaml and set:
#   SYNC_MODE: parallel
#   CLIENT_ID: nas-a          ← required; v3.14 omitted this
#   PARALLEL_WORKERS: 6       ← must fit the CPU limit
kubectl --context cluster-a apply -f cluster-a/deployment-client.yaml

# Watch it. The initial sync runs immediately at pod start, before cron takes over.
kubectl --context cluster-a logs -f deployment/nas-sync-client-deploy -n ea-pmc -c nas-sync-client
```

**Optional but recommended for very large trees:** generate chunks first so the workers get
balanced slices instead of whole top-level folders (guide §8.3):

```bash
kubectl --context cluster-b create job --from=cronjob/nas-sync-chunks seed-chunks -n ea-pmc
kubectl --context cluster-b wait --for=condition=complete job/seed-chunks -n ea-pmc --timeout=14400s
```

Then the bulk log should show `Using 24 server-generated chunks (age=...)`. If it says
`falling back to top-level split`, the chunks were missing or stale — harmless, just slower.

**Done when** the log shows `=== COMPLETE: N chunks, ...s, all OK ===` and the status file
records success:

```bash
kubectl --context cluster-a exec deployment/nas-sync-client-deploy -n ea-pmc -c nas-sync-client -- \
  cat /mnt/nas-target/.nas-sync-status/last-success
```

**Do not** leave the Deployment running as your permanent solution unless you intend to —
go to [S3](#s3--cut-over-bulk--routine).

> **Expect `rsync_rc=24`.** On a live source, files vanishing mid-run is normal; v3.15 maps
> 23/24 to success. A different nonzero code is a real failure.

---

## S3 — Cut over bulk → routine

After the bulk seed completes.

```bash
# 1. Confirm the bulk actually finished (not just that the pod is alive)
kubectl --context cluster-a exec deployment/nas-sync-client-deploy -n ea-pmc -c nas-sync-client -- \
  cat /mnt/nas-target/.nas-sync-status/last-success

# 2. Remove the bulk Deployment
kubectl --context cluster-a delete -f cluster-a/deployment-client.yaml

# 3. Deploy the routine set
kubectl --context cluster-a apply -f cluster-a/cronjob-client.yaml     # incremental, every 2h
kubectl --context cluster-a apply -f cluster-a/cronjob-reconcile.yaml  # parallel, weekly — REQUIRED
kubectl --context cluster-a apply -f cluster-a/cronjob-verify.yaml     # verify, monthly
```

**Mind the gap.** Changes made on the source *during* the bulk are only caught if they fall
inside `lookback_hours`. A multi-day bulk with a 6h lookback leaves a hole. Close it by
running one reconcile immediately:

```bash
kubectl --context cluster-a create job --from=cronjob/nas-sync-reconcile post-bulk -n ea-pmc
kubectl --context cluster-a wait --for=condition=complete job/post-bulk -n ea-pmc --timeout=172800s
```

**Done when** the post-bulk reconcile completes and a verify run reports `drift=0`
([S7](#s7--drift-check)).

---

## S4 — Onboard an additional target while others are live

The interesting case: Target B is in steady state and must not be disturbed while Target C
comes up. It won't be — targets share no write state. The source generator does one walk and
fans out per-client manifests; each client reads only its own.

**The ordering matters.** Register the new client **before** the bulk so its manifest starts
accumulating, but do not start its incremental CronJob until the bulk is done — otherwise it
will try to incrementally patch a tree that doesn't exist yet.

```mermaid
sequenceDiagram
    autonumber
    participant SB as Source NAS B<br/>(.nas-sync-state/)
    participant MG as Manifest CronJob<br/>(Cluster B, shared)
    participant TB as Target B<br/>CLIENT_ID=nas-b (live)
    participant TC as Target C<br/>CLIENT_ID=nas-c (new)

    Note over TB,SB: Steady state — incremental every 2h,<br/>reads clients/nas-b/ only

    Note over MG: Phase 1 — register
    MG->>SB: registry gains "nas-c 6";<br/>next run also writes clients/nas-c/
    Note over TB: Target B unaffected — one walk, separate outputs

    Note over TC: Phase 2 — bulk seed
    TC->>SB: SYNC_MODE=parallel Deployment pulls the full tree<br/>(uses common/chunks/ if fresh)

    Note over TC: Phase 3 — close the gap
    TC->>SB: one reconcile catches everything<br/>changed while the bulk was running

    Note over TC: Phase 4 — steady state
    MG->>SB: each cycle: manifest of changes in nas-c's lookback window
    TC->>SB: incremental pull via clients/nas-c/sync-manifest.txt
    TB->>SB: unchanged — independent window, independent cadence
```

### Checklist

```bash
# 1. REGISTER the new target on Cluster B (§6.2). Add one line to clients.txt:
#      nas-c   6
kubectl --context cluster-b apply -f cluster-b/cronjob-manifests.yaml

#    Confirm the next generator run picks it up:
kubectl --context cluster-b create job --from=cronjob/nas-sync-manifest reg-nas-c -n ea-pmc
kubectl --context cluster-b wait --for=condition=complete job/reg-nas-c -n ea-pmc --timeout=7200s
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.nas-sync-state/clients/nas-c/

# 2. TARGET C shared resources — copy §9A.1, point PV/PVC at THIS target's NAS.
#    Keep namespace ea-pmc. Confirm Bound before continuing.
kubectl --context cluster-c apply -f cluster-c/namespace.yaml
kubectl --context cluster-c apply -f cluster-c/nas-target-pv.yaml
kubectl --context cluster-c apply -f cluster-c/nas-target-pvc.yaml
kubectl --context cluster-c apply -f cluster-c/configmap-exclude.yaml
kubectl --context cluster-c apply -f cluster-c/secret-password.yaml
kubectl --context cluster-c get pvc -n ea-pmc          # must be Bound

# 3. BULK SEED — see S2. SYNC_MODE=parallel, CLIENT_ID=nas-c.
kubectl --context cluster-c apply -f cluster-c/deployment-client.yaml
#    ...wait for completion...
kubectl --context cluster-c delete -f cluster-c/deployment-client.yaml

# 4. ROUTINE SET — CLIENT_ID=nas-c in all three, REMOTE_HOST = the SAME ISTIO_EXTERNAL_IP.
kubectl --context cluster-c apply -f cluster-c/cronjob-client.yaml
kubectl --context cluster-c apply -f cluster-c/cronjob-reconcile.yaml
kubectl --context cluster-c apply -f cluster-c/cronjob-verify.yaml

# 5. CLOSE THE GAP — one reconcile now (see S3).
kubectl --context cluster-c create job --from=cronjob/nas-sync-reconcile post-bulk -n ea-pmc
```

**Stagger the schedules.** Give Target C's weekly reconcile a different day or hour from
Target B's, or N full walks hit the source NAS simultaneously. See [S5](#s5--steady-state).

**Done when** Target C's first incremental logs `Incremental: N changed files` (not
`FULL sync fallback`) and Target B's status file is still advancing normally.

**What did NOT change:** the rsync daemon, the gateway, the generator CronJob, and every
other target. Adding a target is one registry line plus that target's own cluster objects.

---

## S5 — Steady state

What should be running once everything is up.

**On the source cluster (Cluster B), shared by all targets:**

| Object | Cadence | Purpose |
|---|---|---|
| `nas-sync-server` Deployment | always on | rsyncd on 8787 behind the Istio gateway |
| `nas-sync-manifest` CronJob | every 2h at `:50` | one walk → per-client manifests |
| `nas-sync-chunks` CronJob | weekly | one walk → shared chunk lists |

**On each target cluster, per target:**

| Object | Cadence | Purpose |
|---|---|---|
| `nas-sync-client` CronJob | every 2h at `:00` | routine incremental pull |
| `nas-sync-reconcile` CronJob | weekly | full pass — **required**, repairs what mtime can't see |
| `nas-sync-verify` CronJob | monthly | drift detection |

**Why the offsets:** the generator runs at `:50` and the client at `:00`, so the client
always reads a manifest that was just published. Reversing this means every client reads a
two-hour-old manifest.

**Staggering N targets** — the weekly reconcile is a full paired walk. Running three at once
triples source NAS load for the whole window:

```
Target A reconcile:  0 2 * * 0     (Sun 02:00)
Target C reconcile:  0 2 * * 2     (Tue 02:00)
Target D reconcile:  0 2 * * 4     (Thu 02:00)
Chunk generator:     0 0 * * 0     (Sun 00:00 — one run serves all three)
```

Chunks are target-independent, so one weekly chunk job is enough regardless of target count.
Set `CHUNK_MAX_AGE` above the spread (default 24h is too tight for the layout above — raise
it to `604800` if reconciles are spread across the week, or run the chunk job before each).

**Routine health check** — one command, any target:

```bash
kubectl exec <any-client-pod> -n ea-pmc -c nas-sync-client -- \
  sh -c 'cat /mnt/nas-target/.nas-sync-status/last-run; \
         cat /mnt/nas-target/.nas-sync-status/last-success'
```

`last-success` older than 2× the CronJob interval → investigate ([S12](#s12--triage-decision-tree)).

---

## S6 — Change sync mode on a live object

`SYNC_MODE` is an env var, not a build-time choice. No rebuild, no restart of anything else.

```bash
# Simplest:
kubectl edit cronjob nas-sync-client -n ea-pmc      # change SYNC_MODE's value

# Scripted (verify the env index first — it is position-dependent):
kubectl get cronjob nas-sync-client -n ea-pmc \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -n SYNC_MODE

kubectl patch cronjob nas-sync-client -n ea-pmc --type='json' \
  -p='[{"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/env/1/value","value":"parallel"}]'
```

**Applies to the next scheduled run.** To test immediately:

```bash
kubectl create job --from=cronjob/nas-sync-client modecheck -n ea-pmc
kubectl logs -n ea-pmc -l job-name=modecheck | head -5      # confirms "Mode: parallel"
```

**Mode-switch gotchas:**

- → `incremental` requires the generator CronJob running on Cluster B **and** this target
  registered in `clients.txt` with a matching `CLIENT_ID`.
- → `parallel` needs CPU. `PARALLEL_WORKERS: 6` against a `cpu: 1000m` limit will thrash.
- → `verify` writes nothing; safe to run any time, but it takes a full paired walk.
- `incremental` **never seeds** a new target. Switching a cold target to incremental gives
  you a manifest-sized sync onto an empty tree. Bulk first ([S2](#s2--initial-bulk-seed)).

---

## S7 — Drift check

Answering "does the target actually match the source?"

```bash
kubectl create job --from=cronjob/nas-sync-verify drift-$(date +%Y%m%d) -n ea-pmc
kubectl wait --for=condition=complete job/drift-$(date +%Y%m%d) -n ea-pmc --timeout=172800s
kubectl logs -n ea-pmc -l job-name=drift-$(date +%Y%m%d) | grep 'VERIFY RESULT'
```

Result line:

```
VERIFY RESULT mode=meta drift=0 checked=7412330 elapsed=3812s threshold=0
```

**Reading it:**

| Result | Meaning | Action |
|---|---|---|
| `drift=0`, job Completed | Target matches within the metadata tier | Nothing |
| `drift=N`, job Failed | N entries differ | Repair below |
| Job Failed with no RESULT line | Verify itself broke (connectivity, mount) | [S12](#s12--triage-decision-tree) |

**Repair:**

```bash
kubectl create job --from=cronjob/nas-sync-reconcile repair-$(date +%s) -n ea-pmc
# ...then re-run verify and confirm drift returns to 0.
```

**Tiers.** `VERIFY_MODE=meta` (default) compares size + mtime across the whole tree — cheap,
catches nearly everything. `VERIFY_MODE=checksum` reads every byte of a rotating
`1/VERIFY_SLICES` slice, which is the only way to catch content changed with its mtime
preserved, or silent corruption. With the default `VERIFY_SLICES=13`, full byte coverage
takes 13 runs. Run the checksum tier weekly (≈ one quarter for full coverage) rather than
monthly if that matters to you.

**Timing.** Run verify **after** the weekly reconcile, when the tree is at rest. Run it
before, and you are measuring the week's normal churn, not drift.

**Persistent nonzero drift** usually means the sync and verify exclude lists have diverged,
or NAS A rejected some writes. If you have a genuine known baseline, set
`VERIFY_FAIL_THRESHOLD` just above it — do not get used to ignoring a red job.

---

## S8 — Client outage recovery

A target was down (cluster maintenance, network, node pool rebuild). Did it lose changes?

**The honest answer:** the generator advances every cycle whether or not a client consumed
its manifest. A client is safe for outages **shorter than its `lookback_hours`**, because
each manifest covers a window that overlaps the previous one. Beyond that, changes from the
missed window are not in any manifest the client will ever see — until the weekly reconcile
repairs them.

```
lookback = 6h, pull period = 2h

outage 4h   →  next manifest still covers the whole gap        → self-heals, no action
outage 10h  →  hours 6–10 of changes are in no future manifest → run a reconcile
```

### Procedure

```bash
# 1. How long was it actually out?
kubectl exec <pod> -n ea-pmc -c nas-sync-client -- cat /mnt/nas-target/.nas-sync-status/last-success
# Compare that timestamp to now.

# 2. Compare against this client's lookback (Cluster B registry):
kubectl --context cluster-b get configmap nas-sync-clients -n ea-pmc -o yaml | grep -A20 clients.txt
```

**If the outage was shorter than `lookback_hours`:** nothing to do. Let the next scheduled
incremental run and confirm it succeeds.

**If it was longer** — run a reconcile now, do not wait for Sunday:

```bash
kubectl create job --from=cronjob/nas-sync-reconcile outage-repair-$(date +%s) -n ea-pmc
kubectl wait --for=condition=complete job/outage-repair-<ts> -n ea-pmc --timeout=172800s
# Then confirm:
kubectl create job --from=cronjob/nas-sync-verify post-outage -n ea-pmc
```

**If outages of that length are expected**, raise this client's `lookback_hours` in the
registry (§6.2). The cost is a larger manifest and a longer transfer each cycle — cheap
insurance compared to a weekly repair window.

> **Related failure that looks identical:** if the *generator* stopped rather than the
> client, v3.15 fails the client job with `Manifest is STALE` rather than silently
> re-syncing an old manifest. See [S9](#s9--source-side-failure).

---

## S9 — Source-side failure

### The rsync daemon is down

Every target fails simultaneously with `Remote not reachable`.

```bash
kubectl --context cluster-b get pods -n ea-pmc -l role=server
kubectl --context cluster-b logs deployment/nas-sync-server -n ea-pmc -c nas-sync-server --tail=50
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- ss -tlnp | grep 8787
kubectl --context cluster-b get endpoints nas-sync-server -n ea-pmc
kubectl --context cluster-b get svc $INGRESS_SVC -n istio-system | grep 8787
nc -zv ${ISTIO_EXTERNAL_IP} 8787
```

Most common causes, in order: the source NFS mount failed (pod is running but the export is
gone); the ingressgateway lost its 8787 port after an Istio upgrade (re-apply §5.8); the
gateway/VirtualService was garbage-collected.

**Impact while down:** targets fail their runs but lose nothing permanently — the next
successful cycle picks up whatever is in the manifest window. If the outage exceeds
`lookback_hours`, follow [S8](#s8--client-outage-recovery) afterwards.

### The manifest generator stopped

Clients report `Manifest is STALE (…s > …s)` and fail. **This failure is deliberate** — the
alternative is re-syncing a frozen manifest forever while reporting success.

```bash
kubectl --context cluster-b get cronjob nas-sync-manifest -n ea-pmc
kubectl --context cluster-b get jobs -n ea-pmc -l role=manifest \
  --sort-by=.metadata.creationTimestamp | tail -5
kubectl --context cluster-b logs job/<latest> -n ea-pmc
```

| Symptom in the log | Cause | Fix |
|---|---|---|
| `ERROR: registry … not readable` | ConfigMap not mounted / renamed | Re-apply §6.1 |
| `ERROR: no valid clients in registry` | All lines malformed or commented out | Fix `clients.txt` format: `<id> <hours>` |
| `WARN: bad lookback for 'x'` | One bad line; others still processed | Fix that line |
| Job killed at `activeDeadlineSeconds` | The walk now exceeds its budget | Raise it, or check `.snapshot` pruning (§4.3) |
| `Read-only file system` | Source export flipped to `ro` | Fix the export; manifests must be writable |

Recover by fixing the cause and forcing a run:

```bash
kubectl --context cluster-b create job --from=cronjob/nas-sync-manifest recover -n ea-pmc
```

Then clients resume automatically. If the generator was down longer than `lookback_hours`,
run a reconcile per [S8](#s8--client-outage-recovery).

### The source NAS itself was unavailable

Nothing to repair on the target: no `--delete` means nothing was removed. Once the source is
back, run one reconcile per target and a verify to confirm.

---

## S10 — Retire a target

```bash
# 1. Stop that target's scheduled work
kubectl --context cluster-c delete cronjob nas-sync-client nas-sync-reconcile nas-sync-verify -n ea-pmc
kubectl --context cluster-c delete deployment nas-sync-client-deploy -n ea-pmc --ignore-not-found

# 2. Deregister it on the source — remove its line from clients.txt (§6.2)
kubectl --context cluster-b apply -f cluster-b/cronjob-manifests.yaml

# 3. Reclaim its source-side state (optional, safe once deregistered)
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  rm -rf /mnt/nas-source/.nas-sync-state/clients/nas-c

# 4. Target-side cleanup — the DATA is untouched by any of the above.
#    Delete the PVC/PV only if you also intend to release the NAS storage.
kubectl --context cluster-c delete pvc nas-a-target-pvc -n ea-pmc
kubectl --context cluster-c delete pv nas-a-target-pv
```

**Order matters:** deregister *after* stopping the client. Reverse it and the client's next
run finds no manifest and starts a full sync onto a target you are decommissioning.

**Re-adding later** is [S4](#s4--onboard-an-additional-target-while-others-are-live) from
scratch — including the bulk seed, because its manifest history is gone. If the target's
data is still intact, a reconcile substitutes for the bulk and is much faster.

---

## S11 — Version upgrade

Both images carry all the scripts, so an upgrade is: rebuild, push, roll.

```bash
# 1. Update the scripts from the new guide version. Strip CRLF FIRST — a \r in a
#    shebang makes tini fail with "No such file or directory".
sed -i 's/\r$//' cluster-b/scripts/*.sh cluster-a/scripts/*.sh

# 2. Build & push both images with the new tag
cd cluster-b/scripts && docker build -t ${REGISTRY}/nas-sync-server:3.15 . && docker push ${REGISTRY}/nas-sync-server:3.15
cd ../../cluster-a/scripts && docker build -t ${REGISTRY}/nas-sync-client:3.15 . && docker push ${REGISTRY}/nas-sync-client:3.15

# 3. Source side first — it serves every target
kubectl --context cluster-b set image deployment/nas-sync-server nas-sync-server=${REGISTRY}/nas-sync-server:3.15 -n ea-pmc
kubectl --context cluster-b rollout status deployment/nas-sync-server -n ea-pmc
kubectl --context cluster-b apply -f cluster-b/cronjob-manifests.yaml
kubectl --context cluster-b apply -f cluster-b/cronjob-chunks.yaml

# 4. Then each target
kubectl --context cluster-a apply -f cluster-a/cronjob-client.yaml
kubectl --context cluster-a apply -f cluster-a/cronjob-reconcile.yaml
kubectl --context cluster-a apply -f cluster-a/cronjob-verify.yaml

# 5. Prove it on one target before rolling the rest
kubectl --context cluster-a create job --from=cronjob/nas-sync-client upgrade-check -n ea-pmc
kubectl --context cluster-a logs -n ea-pmc -l job-name=upgrade-check
```

**Post-upgrade checks** (guide §11):

```bash
POD=$(kubectl get pods -n ea-pmc -l job-name=upgrade-check -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -n ea-pmc -c nas-sync-client -- head -1 /userapp/scripts/dispatch-sync.sh | cat -A   # #!/bin/bash$
kubectl exec $POD -n ea-pmc -c nas-sync-client -- ls /userapp/scripts/                                  # new scripts present
kubectl logs $POD -n ea-pmc -c nas-sync-client | grep -E 'client=|Incremental:|FULL sync fallback'
```

**Rollback** is a tag change — no state migration is involved in either direction:

```bash
kubectl set image cronjob/nas-sync-client nas-sync-client=${REGISTRY}/nas-sync-client:3.14 -n ea-pmc
```

**Upgrading v3.14 → v3.15 specifically:** see the migration appendix at the end of the guide.
Nothing on the source NAS needs migrating; `common/chunks/` is created on first use. The one
thing you must not skip is adding `CLIENT_ID` to the Deployment (§10B.1) if it runs
`incremental`.

---

## S12 — Triage decision tree

Start with the status file. It answers "is this broken, or was it always broken?"

```bash
kubectl exec <pod> -n ea-pmc -c nas-sync-client -- \
  sh -c 'cat /mnt/nas-target/.nas-sync-status/last-run; cat /mnt/nas-target/.nas-sync-status/last-success'
```

| Symptom | Most likely cause | Go to |
|---|---|---|
| Pod stuck `NotReady`, job never completes | Istio sidecar wasn't quit | guide §13 "Pod stuck NotReady" |
| `tini exec … No such file or directory` | CRLF in a script | guide §13; rebuild after `sed -i 's/\r$//'` |
| `Remote not reachable` but the source is healthy | Sidecar-start race | guide §13; add the §9A.2 annotation, raise `PREFLIGHT_RETRIES` |
| `Remote not reachable` on **every** target at once | Source side down | [S9](#s9--source-side-failure) |
| Job `Failed`, log looks fine, `rsync_rc=24` | Normal — files vanished mid-run | Nothing; v3.15 maps 23/24 to success |
| `Manifest fetch failed — FULL sync fallback` | `CLIENT_ID` unset, unregistered, or misspelled | Below |
| `Manifest is STALE` | Generator stopped | [S9](#s9--source-side-failure) |
| Verify job `Failed`, `drift=N` | Real divergence | [S7](#s7--drift-check) |
| `falling back to top-level split` | Chunks missing/stale | Harmless; guide §13 "Chunks stale" |
| Sync succeeds but new files never appear | Renames, empty dirs, or beyond lookback | guide §12.1, then [S8](#s8--client-outage-recovery) |
| `last-success` is old, `last-run` is recent | Runs are failing; read `exit=` | Follow that exit code |
| Neither status file exists | No v3.15 run completed, or target not writable | Check the PVC and the export (S0) |
| PVC `Pending` | PV/NFS mismatch | [S0](#s0--prerequisites--values-worksheet) |

### `FULL sync fallback` — the three causes

This one is worth expanding because it is silent: the sync *succeeds*, it is just enormously
more expensive than intended and takes the lookback logic out of play.

```bash
# 1. Is CLIENT_ID set on the object at all? (v3.14's Deployment omitted it entirely.)
kubectl get cronjob nas-sync-client -n ea-pmc \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -A1 CLIENT_ID

# 2. Is it registered on the source, spelled identically?
kubectl --context cluster-b get configmap nas-sync-clients -n ea-pmc -o yaml | grep -A20 clients.txt

# 3. Did the generator actually write that client's manifest?
kubectl --context cluster-b exec deployment/nas-sync-server -n ea-pmc -c nas-sync-server -- \
  ls -la /mnt/nas-source/.nas-sync-state/clients/<CLIENT_ID>/
```

If you are on a **Deployment** and the CronJob works but the Deployment doesn't, it is the
v3.14 env allow-list bug — the fix is in v3.15 §8.7 and requires the rebuilt image.

---

## S13 — Tuning

| Knob | Where | Raise it when | Cost of raising |
|---|---|---|---|
| `lookback_hours` | registry, §6.2 | Outages exceed the window ([S8](#s8--client-outage-recovery)) | Larger manifest, longer transfer each cycle |
| `PARALLEL_WORKERS` | client env | Reconcile too slow and CPU is idle | Needs CPU limit headroom; more concurrent NAS load |
| `CHUNK_COUNT` | §6.3 | Workers finish unevenly | More, smaller chunk files on the source NAS |
| `CHUNK_MAX_AGE` | client env | Reconciles are staggered across the week ([S5](#s5--steady-state)) | Older chunks may miss recently added files (the reconcile still transfers them, just unbalanced) |
| `MANIFEST_MAX_AGE` | client env | Generator legitimately runs less often than daily | Weakens the stale-generator guard |
| `RSYNC_TIMEOUT` | client env | Large files over a slow link time out mid-transfer | A genuinely hung transfer takes longer to fail |
| `activeDeadlineSeconds` | CronJob spec | Jobs are killed while still making progress | A hung job occupies the slot longer |
| `VERIFY_SLICES` | verify env | You want full checksum coverage faster | Each run reads more bytes on both NASes |

**Rules of thumb:**

- `lookback_hours` ≥ pull period × 2, and always greater than the generator's walk time.
  The generator captures its threshold at the *start* of the walk but publishes at the
  *end*; a client polling mid-walk reads the previous manifest.
- `PARALLEL_WORKERS` ≤ CPU limit in cores. `6` workers against `cpu: 4000m` is reasonable;
  against `1000m` it thrashes.
- `CHUNK_COUNT` should **exceed** `PARALLEL_WORKERS` (default 24 vs 6) so fast workers keep
  pulling instead of idling at the end.
- `activeDeadlineSeconds` for the reconcile must exceed its observed runtime with margin.
  The guide ships `172800` (48h) for exactly this reason; the routine incremental's `86400`
  is fine because it only moves the diff.

**Measuring before tuning:**

```bash
# How long do runs actually take, and how much do they move?
kubectl logs -n ea-pmc -l role=client --tail=200 | grep 'COMPLETE'
kubectl logs -n ea-pmc -l role=client --tail=200 | grep 'Incremental:'
# Generator walk time:
kubectl --context cluster-b logs -n ea-pmc -l role=manifest --tail=100 | grep -E 'Walking|Done'
```

---

## S14 — Read-only source

If the source NFS export cannot be made writable, `incremental` mode is unavailable: the
generator writes manifests into `.nas-sync-state/` on the source NAS, and the chunk generator
writes `common/chunks/` there too.

**What still works:**

| Mode | Read-only source? |
|---|---|
| `standard` | Yes |
| `parallel` (top-level split fallback) | Yes |
| `parallel` (chunked) | No — chunks are written to the source |
| `incremental` | No — manifests are written to the source |
| `verify` | Yes — `--dry-run`, writes nothing anywhere |

**Configuration:**

```yaml
# cluster-b/deployment-server.yaml (§5.4)
volumes:
  - name: nas-source
    nfs:
      server: "10.90.220.155"
      path: "/PMCenterData"
      readOnly: true          # ◄ read-only source
```

Do not deploy `cronjob-manifests.yaml` (§6.1) or `cronjob-chunks.yaml` (§6.3) — both will
fail on the first write.

**Target-side setup:** run the routine sync as `parallel` rather than `incremental`, on a
cadence you can afford. Every run is a full paired walk, so pick the interval from the walk
time, not from your desired RPO.

```
Routine:   CronJob + SYNC_MODE=parallel   (e.g. nightly)
Verify:    CronJob + SYNC_MODE=verify     (monthly — still works)
```

**The trade-off:** you lose the cheap 2-hourly change-list sync, and your effective RPO
becomes the full-walk interval. If a small writable location exists anywhere on the source
NAS — even a separate small export — pointing `STATE_DIR` at it restores `incremental`:

```yaml
env:
  - name: STATE_DIR
    value: "/mnt/nas-state/.nas-sync-state"    # a second, writable mount
```

The generator writes there and the client fetches from there, provided that path is also
exposed by an rsyncd module the client can read.

---

## Related documents

- `cross-cluster-rsync-guide-v3.15-consolidated.md` — the reference: every file and flag
- `docs/reviews/2026-07-22-nas-sync-architecture-review.md` — why the design is what it is,
  and every defect fixed in v3.15
- `scripts/check-guide.sh` — consistency harness; run before committing guide edits
