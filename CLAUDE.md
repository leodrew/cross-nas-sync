# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This directory is a **documentation reference**, not a buildable project. It contains one authoritative guide for deploying a cross-cluster NAS rsync system on Kubernetes + Istio. The markdown *is* the source of truth: its fenced code blocks (shell scripts, Dockerfiles, YAML manifests) are meant to be copied verbatim into real files at deploy time.

| File | Contents |
|------|----------|
| `cross-cluster-rsync-guide-v3.13-consolidated.md` | **Authoritative v3.13 reference.** Consolidates all prior versions (v3.4–v3.12 + DNS/speedup fixes). Every script, Dockerfile, and K8s/Istio manifest for both clusters, plus verify/troubleshooting steps. |

The version is encoded in the filename. `§14 → What This Consolidates` maps each capability to the version it originated in — treat that table as the changelog.

## What the Guide Deploys

A one-way rsync replication from **NAS B → NAS A** across two Kubernetes clusters, fronted by Istio:

```
NAS B (source, NFS ro)          NAS A (target, NFS rw)
10.90.220.155:/PMCenterData     10.19.192.228:/srv/nfs/data
        │                                  ▲
        ▼                                  │ pull (rsync :8787)
  Cluster B                          Cluster A
  rsync daemon (Deployment)   ◄────  client (CronJob OR Deployment)
  + manifest CronJob                 standard / parallel / incremental
  exposed via Istio GW/VS            sidecar-quit wrapper
```

Fixed conventions throughout: **port 8787**, namespace **`ea-pmc`**, **delete disabled** (target-only files are preserved — never add `--delete`), **console-only logging**, `--whole-file` (faster across the Istio proxy). Target scale that drives the design choices: ~7.4M folders with a ~0.17% change rate.

## The Two Orthogonal Axes (the core mental model)

The client is **one image** whose behavior is selected by two independent choices that combine freely:

1. **K8s type** — *how the container lives*
   - **CronJob** → default ENTRYPOINT runs `run-with-sidecar-quit.sh` (sync once, then quit the sidecar so the Job pod can complete).
   - **Deployment** → overrides `command:` to `entrypoint-deployment.sh` (initial unbounded sync + internal cron loop; sidecar runs forever).
2. **`SYNC_MODE` env var** — *which algorithm runs*, dispatched by `dispatch-sync.sh`:
   - `standard` → `nas-sync-client.sh` (single rsync)
   - `parallel` → `nas-sync-parallel.sh` (N workers split by top-level folder; needs CPU + tuned `PARALLEL_WORKERS`)
   - `incremental` → `nas-sync-incremental.sh` (syncs only files in a server-generated manifest)

`SYNC_MODE` can be changed on a live object without rebuilding (`kubectl edit/patch cronjob`). Recommended for the target scale: routine `incremental` CronJob every 2h, weekly `parallel` reconcile, initial bulk via `parallel` Deployment.

## Non-Obvious Design Decisions (the reasons behind the code)

These are the constraints that explain why the scripts/manifests look the way they do — preserve them when editing:

- **CRLF will silently break everything.** A `\r` in a script shebang causes `tini exec ... No such file or directory`. Both Dockerfiles run `dos2unix` *and* fail the build if any CRLF remains (`§4.4`, `§8.8`). On Windows especially, never reintroduce CRLF into the fenced shell scripts.
- **Istio sidecar must be quit for CronJob/Job pods**, or the pod hangs `NotReady` forever after the sync finishes. `run-with-sidecar-quit.sh` POSTs to `/quitquitquit` with four fallbacks (curl → wget → pilot-agent → bash `/dev/tcp`) so it works regardless of which tools the injected sidecar provides. Deployment pods deliberately do *not* quit the sidecar.
- **`reverse lookup = no`** in `rsyncd.conf` fixes a DNS stall caused by the Istio `127.0.0.6` source address (`§5.2`).
- **`incremental` mode requires the manifest CronJob on Cluster B** (`§6`). `generate-manifest.sh` writes `.sync-manifest.txt` *into the source NAS* (so that NFS mount must be `readOnly: false`), using a marker file + `find -newer`. First run emits the literal `FULL_SYNC`; the client falls back to a full sync if the manifest is missing or signals `FULL_SYNC`.
- **`SPRING`-style merge note doesn't apply here** — but ConfigMaps/Secrets are mounted via `subPath` (single-file mounts) so they don't clobber the directory; read-only mounts are never `chmod`-ed.

## "Commands" in this repo

There is nothing to build or test locally. The operational commands live in the guide and target real clusters:

```bash
# Build & push images (run once per cluster, from the scripts/ dir; strip CRLF first)
docker build -t ${REGISTRY}/nas-sync-server:3.13 .   # Cluster B (§4.5)
docker build -t ${REGISTRY}/nas-sync-client:3.13 .   # Cluster A (§8.9)

# Deploy order (see §14 → Deploy Order): server+GW → (manifest job) → verify → client
kubectl apply -f cluster-b/...        # then cluster-a/...

# Verify a CronJob run end-to-end
kubectl create job --from=cronjob/nas-sync-client test -n ea-pmc
kubectl logs <pod> -n ea-pmc -c nas-sync-client
kubectl exec <pod> -n ea-pmc -c nas-sync-client -- head -1 /userapp/scripts/dispatch-sync.sh | cat -A
#   expect: #!/bin/bash$   (a trailing ^M means the CRLF guard regressed)
```

## When Editing the Guide

The document is heavily self-referential. If you add or move content, keep these in sync or the guide breaks for the next reader:
- **Section numbers** (`§4.2`, `§8.6`, …) — cross-referenced from the Table of Contents, the File Checklist (`§14`), and inline prose.
- **The File Checklist (`§14`)** must list every script/manifest the guide defines, with its section number.
- **The "What This Consolidates" table** — update it when adding a capability so the version provenance stays accurate.
- Any change to a script or manifest must remain copy-paste-ready (valid shell/YAML, LF line endings, placeholders like `your-registry.example.com` and `ISTIO_EXTERNAL_IP_HERE` left intact and marked `◄ MODIFY`).
