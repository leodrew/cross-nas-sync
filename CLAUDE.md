# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This directory is a **documentation reference**, not a buildable project. It contains the guide for deploying a cross-cluster NAS rsync system on Kubernetes + Istio. The markdown *is* the source of truth: its fenced code blocks (shell scripts, Dockerfiles, YAML manifests) are meant to be copied verbatim into real files at deploy time.

| File | Contents |
|------|----------|
| `cross-cluster-rsync-guide-v3.15-consolidated.md` | **Authoritative reference.** Every script, Dockerfile, and K8s/Istio manifest for both clusters, plus verify/troubleshooting steps. Consolidates v3.4–v3.14 and adds the v3.15 hardening + defect fixes. |
| `docs/nas-sync-operations-runbook.md` | **Operator procedures.** Scenario-driven (S0–S14): greenfield, bulk seed, onboarding a target while others are live, outage recovery, retirement, upgrade, triage, tuning. Cross-links into the guide's § numbers. |
| `docs/reviews/2026-07-22-nas-sync-architecture-review.md` | **Why the design is what it is.** Architecture verdict, alternatives, the limits of mtime-based change detection, and all 16 findings fixed in v3.15. |
| `scripts/check-guide.sh` | Consistency harness for the guide. **Run before every commit that touches a guide.** |
| `cross-cluster-rsync-guide-v3.14-consolidated.md`, `...v3.13...` | History. Do not edit; do not deploy from. |

The version is encoded in the filename. `§14 → What This Consolidates` maps each capability to the version it originated in — treat that table as the changelog.

`docs/superpowers/specs/` and `docs/superpowers/plans/` hold design history. The `2026-07-05-rsync-hardening-v315` spec and plan are **superseded** (they target v3.13 and assume a state model v3.14 replaced) — both carry a banner explaining what shipped instead. Do not implement from them.

## What the Guide Deploys

A one-way rsync replication from **NAS B → NAS A** across two Kubernetes clusters, fronted by Istio. One source can feed **many targets**:

```
NAS B (source, NFS rw*)         NAS A (target, NFS rw)      NAS C, NAS D, …
10.90.220.155:/PMCenterData     10.19.192.228:/srv/nfs/data
        │                                  ▲                       ▲
        ▼                                  │ pull (rsync :8787)    │
  Cluster B                          Cluster A               Cluster C…
  rsync daemon (Deployment)   ◄────  client (CronJob OR Deployment)
  + manifest CronJob  ────────────►  standard / parallel / incremental / verify
  + chunk CronJob                    sidecar-quit wrapper
  exposed via Istio GW/VS            CLIENT_ID selects this target's manifest
```

\* The source mount must be **read-write** for `incremental` (manifests) and chunked `parallel` (chunk lists) — both are written into `.nas-sync-state/` on the source NAS. A read-only source restricts you to `standard`/`parallel`/`verify`; see runbook S14.

Fixed conventions throughout: **port 8787**, namespace **`ea-pmc`**, **delete disabled** (target-only files are preserved — never add `--delete`), **console-only logging**, `--whole-file` (faster across the Istio proxy). Target scale that drives the design choices: ~7.4M folders with a ~0.17% change rate.

## The Three Orthogonal Axes (the core mental model)

The client is **one image** whose behavior is selected by three independent choices that combine freely:

1. **K8s type** — *how the container lives*
   - **CronJob** → default ENTRYPOINT runs `run-with-sidecar-quit.sh` (sync once, then quit the sidecar so the Job pod can complete).
   - **Deployment** → overrides `command:` to `entrypoint-deployment.sh` (initial unbounded sync + internal cron loop; sidecar runs forever). Used for the initial bulk seed.
2. **`SYNC_MODE` env var** — *which algorithm runs*, dispatched by `dispatch-sync.sh`:
   - `standard` → `nas-sync-client.sh` (single rsync)
   - `parallel` → `nas-sync-parallel.sh` (N workers over server-generated chunk lists, falling back to a top-level-folder split)
   - `incremental` → `nas-sync-incremental.sh` (syncs only files in a server-generated manifest)
   - `verify` → `nas-sync-verify.sh` (**`--dry-run` only** — reports drift, transfers nothing, fails the Job when drift exceeds a threshold)
3. **`CLIENT_ID` env var** — *which target this is*. Selects the per-client manifest at `.nas-sync-state/clients/<CLIENT_ID>/`. Must match a line in the `clients.txt` registry ConfigMap on Cluster B (§6.2). Adding a target = adding one registry line + that target's own cluster objects.

`SYNC_MODE` can be changed on a live object without rebuilding (`kubectl edit/patch cronjob`).

**Recommended layout per target:** routine `incremental` CronJob every 2h, **required** weekly `parallel` reconcile, monthly `verify`, initial bulk via `parallel` Deployment.

## Non-Obvious Design Decisions (the reasons behind the code)

These are the constraints that explain why the scripts/manifests look the way they do — preserve them when editing:

- **CRLF will silently break everything.** A `\r` in a script shebang causes `tini exec ... No such file or directory`. Both Dockerfiles run `dos2unix` *and* fail the build if any CRLF remains (`§4.4`, `§8.8`). On Windows especially, never reintroduce CRLF into the fenced shell scripts. `scripts/check-guide.sh` counts CR bytes with `tr`, not `grep` — MSYS grep strips a CR pattern from argv and silently matches every line.
- **Istio sidecar must be quit for CronJob/Job pods**, or the pod hangs `NotReady` forever after the sync finishes. `run-with-sidecar-quit.sh` POSTs to `/quitquitquit` with four fallbacks (curl → wget → pilot-agent → bash `/dev/tcp`) so it works regardless of which tools the injected sidecar provides. Deployment pods deliberately do *not* quit the sidecar.
- **Istio also races the sidecar at startup.** Every client pod template carries `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'`, and the mode scripts retry the preflight (`PREFLIGHT_RETRIES`). Without both, a cold start fails with a false "Remote not reachable".
- **`reverse lookup = no`** in `rsyncd.conf` fixes a DNS stall caused by the Istio `127.0.0.6` source address (`§5.2`).
- **`incremental` requires the manifest CronJob on Cluster B** (`§6`). `generate-manifests.sh` does **one** `find` walk and fans out a per-client manifest using a **stateless lookback window** (no marker files) — each client's window is `lookback_hours` from the registry. Manifests are written *into the source NAS* under `.nas-sync-state/clients/<id>/`, so that mount must be `readOnly: false`. A client with no manifest falls back to a full sync.
- **mtime detection has hard limits** (`§12.1`): renames/moves, new empty directories, directory metadata, and mtime-preserved content changes are all invisible to `incremental`. The **weekly `parallel` reconcile (`§9A.4`) is a required compensating control, not an optional extra**, and `verify` (`§9A.5`) is what proves any of it is working. Never present the reconcile as optional.
- **rsync exit codes 23 and 24 are normal** on a live source (files vanish mid-run). All mode scripts map them to success via `rsync_rc_ok()`. Do not "fix" this by propagating them.
- **`--partial-dir=.rsync-partial`, not bare `--partial`.** Bare `--partial` leaves truncated files at their real names on the target, where readers see corrupt data.
- ConfigMaps/Secrets are mounted via `subPath` (single-file mounts) so they don't clobber the directory; read-only mounts are never `chmod`-ed.

## "Commands" in this repo

There is nothing to build or test locally, with one exception: **the guide checker**.

```bash
# ALWAYS run after editing a guide — this is the repo's test suite
bash scripts/check-guide.sh                      # newest guide
bash scripts/check-guide.sh <guide.md>           # a specific one
```

It verifies: CR bytes, `bash -n` on every fenced bash block, YAML parse on every fenced yaml block, absence of `--delete`, placeholder integrity, that every `§ref` resolves to a real heading, that every defined file appears in the §14 checklist, and that each v3.15 defect fix is still present. Needs `pyyaml` for full YAML parsing (`pip install pyyaml`); degrades to a structural check without it.

The operational commands live in the guide and target real clusters:

```bash
# Build & push images (run once per cluster, from the scripts/ dir; strip CRLF first)
docker build -t ${REGISTRY}/nas-sync-server:3.15 .   # Cluster B (§4.5)
docker build -t ${REGISTRY}/nas-sync-client:3.15 .   # Cluster A (§8.9)

# Deploy order (see §14 → Deploy Order): server+GW → (manifest/chunk jobs) → verify → client → reconcile → verify job
kubectl apply -f cluster-b/...        # then cluster-a/...

# Verify a CronJob run end-to-end
kubectl create job --from=cronjob/nas-sync-client test -n ea-pmc
kubectl logs <pod> -n ea-pmc -c nas-sync-client
kubectl exec <pod> -n ea-pmc -c nas-sync-client -- head -1 /userapp/scripts/dispatch-sync.sh | cat -A
#   expect: #!/bin/bash$   (a trailing ^M means the CRLF guard regressed)

# Is it actually working? (v3.15 status file — no pod logs needed)
kubectl exec <pod> -n ea-pmc -c nas-sync-client -- cat /mnt/nas-target/.nas-sync-status/last-success
```

## When Editing the Guide

The document is heavily self-referential. If you add or move content, keep these in sync or the guide breaks for the next reader:

- **Never renumber existing sections.** `§4.2`, `§8.6`, … are cross-referenced from the Table of Contents, the File Checklist (`§14`), inline prose, the runbook, and the review. New content gets a new number appended after the existing ones, even when that makes the reading order slightly odd (see §4.6 and §8.10, which follow their own Build & Push sections deliberately).
- **The File Checklist (`§14`)** must list every script/manifest the guide defines, with its section number.
- **The "What This Consolidates" table** — update it when adding a capability so the version provenance stays accurate.
- **A new script means four edits, not one:** the section defining it, the Dockerfile `COPY` list, the `dos2unix` + CRLF-guard lists in that same Dockerfile, and the §14 checklist.
- Any change to a script or manifest must remain copy-paste-ready (valid shell/YAML, LF line endings, placeholders like `your-registry.example.com` and `ISTIO_EXTERNAL_IP_HERE` left intact and marked `◄ MODIFY`).
- **Never add `--delete`** in any form. Target-only files are preserved by policy; the orphan copies this leaves after a rename are a known, accepted cost (§12.1).
- **Run `bash scripts/check-guide.sh` before committing.** It catches every item above.
