# Multi-Target Incremental Sync — Design Spec (v3.14)

- **Date:** 2026-06-20
- **Status:** Approved — ready for implementation plan
- **Supersedes:** `cross-cluster-rsync-guide-v3.13-consolidated.md` (single-target incremental)
- **Deliverable:** new standalone guide `cross-cluster-rsync-guide-v3.14-consolidated.md`

---

## 1. Problem

The v3.13 incremental design keeps **one** global marker (`last-sync-marker`) and writes **one**
`.nas-sync-state/sync-manifest.txt` on source NAS B. The single client (Cluster A) fetches that
manifest and runs `rsync --files-from`.

Source NAS B must now feed **many** target NAS servers, each in its **own** Kubernetes cluster,
all pulling from the single source rsync daemon. The single-manifest model breaks:

1. **No per-client distinction** — every client would fetch the same `sync-manifest.txt`.
2. **Shared marker corrupts coverage** — the marker advances on each generation, so a target that
   pulls on a different cadence, or misses a window, permanently loses those files until the weekly
   `parallel` reconcile.
3. **Generation cost at scale** — at ~7.4M folders, running a separate `find -newer` walk *per
   client* multiplies stat load on the source NAS.

## 2. Goals

- Each target gets its **own** manifest, keyed by a unique `CLIENT_ID`.
- The change-window is tracked **statelessly** per client (no marker files to corrupt/reset).
- Missing/failed pulls are **self-healing** within a configurable window.
- Manifest generation is **one walk total**, independent of target count.
- The source NAS data module stays **read-only**; clients only read their manifest.
- Adding/removing a target is a **single-place** edit (a registry), plus deploying that target's client.
- A new standalone guide a reader can follow top-to-bottom, mirroring v3.13's structure.

## 3. Non-Goals

- Exact-once / minimal-redundancy delivery (rejected: client-confirmed write-back model — see §4).
- Bi-directional or delete-propagating sync (`--delete` remains forbidden, target-only files preserved).
- Changing the rsync daemon, ports (8787), namespace (`ea-pmc`), logging, or any v3.13 invariant
  not listed in §10.

## 4. Decisions & Rationale

| # | Decision | Rationale | Alternatives rejected |
|---|----------|-----------|-----------------------|
| D1 | **Per-client lookback window** (stateless): each manifest = files changed in the last `N` hours for that client. | No marker state; overlapping windows mean a client gets several chances at each change, so a missed pull self-heals within `N`. Source stays read-only. | (a) *Marker, advance-on-generation* — leanest per run but a missed pull loses files until weekly reconcile. (b) *Client-confirmed marker write-back* — exact coverage but needs a writable rsync module on the source + client write step; too much machinery for the benefit at this change rate. |
| D2 | **Single `find` walk + streaming `awk` fan-out** produces all N manifests in one pass. | At 7.4M folders the walk is the dominant cost; doing it once instead of once-per-client keeps adding targets near-free. | One CronJob per client (N full walks) — multiplies source stat load. |
| D3 | **Client registry as a ConfigMap on Cluster B** mapping `CLIENT_ID → lookback hours`. | Single source of truth; add/remove a target by editing one object. Mounted into the generator. | Hard-coding clients in the script; per-client CronJobs. |
| D4 | **Bootstrap new targets via an initial `parallel` sync** (Deployment), then switch to incremental CronJob. | A lookback window never contains the *whole* dataset, so a fresh target must be seeded fully first. Reuses the existing §12 pattern. | Emitting `FULL_SYNC` per new client — reintroduces per-client state. |
| D5 | **Weekly `parallel` reconcile per target is retained** as the backstop. | Covers outages longer than any client's `N`, and any drift. | Relying on incremental alone. |
| D6 | **New consolidated v3.14 guide** (standalone), superseding v3.13. | User will follow one self-contained file end-to-end. | Companion delta doc layered on v3.13. |

## 5. Architecture

```
                      Cluster B (source)
   ┌─────────────────────────────────────────────────┐
   │  rsyncd [nas-data] (read only = yes, :8787)       │
   │  multi-client manifest generator (CronJob)        │
   │  client-registry ConfigMap (id → lookback hours)  │
   └───────────────┬───────────────────────────────────┘
   source NAS B  .nas-sync-state/clients/<CLIENT_ID>/sync-manifest.txt
                   │            │              │
        pull mft + │            │              │
        rsync data ▼            ▼              ▼
              Cluster A     Cluster C      Cluster D …
              CLIENT_ID=    CLIENT_ID=     CLIENT_ID=
              nas-a         nas-c          nas-d
```

- One source rsync daemon; one manifest generator; one registry.
- N independent client clusters, each replicating the v3.13 Cluster A pattern with a distinct `CLIENT_ID`.

## 6. Components

### 6.1 State layout on source NAS

```
${SOURCE_PATH}/.nas-sync-state/
└── clients/
    ├── <CLIENT_ID>/
    │   ├── sync-manifest.txt     # relative paths (%P) changed within this client's window
    │   └── manifest.meta         # generated_at_epoch, window_hours, file_count
    └── …
```

- Written only by the generator CronJob (NFS mount `readOnly: false` on B).
- No marker files (stateless model).
- Exposed for reading through the existing `[nas-data]` module (clients fetch
  `rsync://…/nas-data/.nas-sync-state/clients/<CLIENT_ID>/sync-manifest.txt`).
- `.nas-sync-state/` MUST remain excluded **client-side** (`rsync-exclude.txt`) from
  standard/parallel/full data syncs so targets never accumulate the state dir.

### 6.2 Client registry (ConfigMap on Cluster B)

Plain-text, shell/awk-parseable. One client per line: `<CLIENT_ID> <LOOKBACK_HOURS>`; `#` comments allowed.

```
# client-id   lookback-hours
nas-a         6
nas-c         6
nas-d         48
```

- Mounted into the generator pod via `subPath` (single-file mount, per the project convention).
- Adding a target = add a line here + deploy that target's client. Removing = delete the line
  (stale `clients/<id>/` dirs may be cleaned up manually; documented in the guide).

### 6.3 Manifest generator (`generate-manifests.sh`, replaces `generate-manifest.sh`)

Single walk, streaming fan-out:

1. Read registry → arrays of `CLIENT_ID` and `LOOKBACK_HOURS`.
2. Compute `now_epoch`; per client `threshold[id] = now_epoch − LOOKBACK_HOURS·3600`.
3. For each client, ensure `clients/<id>/` exists and open a temp manifest `sync-manifest.txt.tmp`.
4. One `find "$SOURCE_PATH"` walk, pruning `.snapshot`/snapshot dirs and `$STATE_DIR`,
   `-type f -printf '%T@ %P\n'`, piped to a single `awk` pass.
5. `awk` routes each line: for every client whose `threshold` is `< file_mtime`, append the path
   to that client's `.tmp` manifest. (`%T@` is a float epoch; compare as numbers.)
6. After the walk completes, for each client: write `manifest.meta`
   (`generated_at`, `window_hours`, `file_count`), then **atomically** `mv` the `.tmp` files into place.
7. Console logging only; `set +e`; never `--delete` anything.

Cost: **one** walk regardless of client count. Intermediate routing is streamed (no need to
materialize the full `%T@ %P` list to disk).

Atomicity: clients always read a complete manifest because publish is a same-directory `mv`.

### 6.4 Client side (`nas-sync-incremental.sh`, minimal change)

- New env `CLIENT_ID` (required for incremental mode).
- Derive `MANIFEST_NAME=".nas-sync-state/clients/${CLIENT_ID}/sync-manifest.txt"`
  (still overridable by explicit `MANIFEST_NAME`).
- Unchanged behavior: fetch manifest → `rsync --files-from` with the v3.13 flags
  (`-a --whole-file --partial --timeout`, password file, exclude file).
- **Empty manifest** (no changes in window) → log "nothing changed", exit 0.
- **Missing manifest** (fetch fails / client not yet in registry) → FULL sync fallback, logged as
  degraded.
- Dispatcher (`dispatch-sync.sh`), sidecar-quit wrapper, `standard`/`parallel` modes: unchanged.

### 6.5 Generator CronJob (`cronjob-manifests.yaml`, replaces `cronjob-manifest.yaml`)

- Runs at the **most-frequent** client cadence (e.g. every 2h), `concurrencyPolicy: Forbid`.
- Reuses the server image; `command` runs `generate-manifests.sh`.
- Mounts: source NAS (`readOnly: false`) + registry ConfigMap (`subPath`).
- `sidecar.istio.io/inject: "false"` (as today).

## 7. Data flow (one cycle)

1. Generator CronJob fires on B → reads registry → one `find` walk → writes per-client manifests
   atomically to `.nas-sync-state/clients/<id>/`.
2. Each target's client CronJob fires (scheduled after the generator) → fetches its own
   `clients/<CLIENT_ID>/sync-manifest.txt` over `[nas-data]`.
3. Client runs `rsync --files-from` pulling only listed files; already-synced overlap entries are
   stat-checked and **skipped** (mtime matches). No `--delete`.
4. Client (CronJob) quits its Istio sidecar so the Job pod completes.

## 8. Window sizing & scheduling

- `N = pull_period × 2–3`, or `pull_period + worst tolerated outage`.
  - 2h client → `N = 6h`; daily client → `N = 26–48h`.
- Generator runs at the most-frequent client cadence; every run regenerates all manifests from
  `now − N`. Stateless → safe to run as often as desired (cost = one walk).
- Outages longer than a client's `N` are recovered by that target's **weekly `parallel` reconcile**.

## 9. Failure modes & handling

| Failure | Behavior |
|---------|----------|
| Client misses one (or a few) pulls, within `N` | Next pull's overlapping window still lists the files → recovered automatically. |
| Client down longer than `N` | Files older than `N` are missed by incremental; weekly `parallel` reconcile recovers them. |
| Client not yet in registry / manifest missing | Client logs degraded + does a FULL sync fallback (correct but heavy); operator should add it to the registry and/or run the parallel bootstrap. |
| Generator crashes mid-run | `Forbid` prevents overlap; temp `.tmp` files are not published (atomic `mv` never ran); clients keep reading the previous good manifest. Orphan `.tmp` files cleaned at next run start. |
| New target | Seed with initial `parallel` Deployment, add registry line, then enable incremental CronJob. |
| Removed target | Delete registry line; optionally remove its `clients/<id>/` dir manually. |

## 10. Preserved invariants (must not regress)

- Port **8787**, namespace **`ea-pmc`**, **delete disabled** (never add `--delete`).
- Console-only logging; `--whole-file`.
- **Sidecar-quit** for CronJob/Job pods; Deployment pods do *not* quit the sidecar.
- **CRLF guards**: Dockerfiles run `dos2unix` and fail the build on any remaining CR; all fenced
  scripts stay LF-only.
- `reverse lookup = no` in `rsyncd.conf`.
- ConfigMaps/Secrets mounted via `subPath`; read-only mounts never `chmod`-ed.
- `[nas-data]` stays `read only = yes`; `.nas-sync-state/` excluded client-side from data syncs.

## 11. Deliverable structure — `cross-cluster-rsync-guide-v3.14-consolidated.md`

Mirror v3.13's layout, with these changes (renumber sections consistently and keep the TOC,
File Checklist, and "What This Consolidates" in sync):

- **CLAUDE.md-style intro / mental model:** add the multi-target axis (one source → N targets,
  per-client manifests, stateless lookback).
- **Server (Cluster B):**
  - Replace `generate-manifest.sh` (§4.3) with `generate-manifests.sh` (single-walk fan-out).
  - Add the **client-registry ConfigMap** section.
  - Update the server Dockerfile to COPY/`dos2unix`/CRLF-check the new script name.
- **Generator deploy:** replace `cronjob-manifest.yaml` with `cronjob-manifests.yaml`
  (registry ConfigMap mounted via `subPath`).
- **Client (target clusters):**
  - `nas-sync-incremental.sh` gains `CLIENT_ID` → per-client `MANIFEST_NAME`.
  - **Per-target deploy walkthrough:** how to stand up target #2, #3… (set `CLIENT_ID`,
    point at the source GW/VS, bootstrap with `parallel`, then incremental + weekly reconcile).
- **Verify:** per-client checks (manifest exists for each `CLIENT_ID`, file counts, a CronJob test
  run per target).
- **Troubleshooting:** per-client manifest-not-found, client-missing-from-registry,
  degraded-to-full-sync, plus the existing CRLF/sidecar items.
- **§14 File Checklist:** list every new/renamed script & manifest with section numbers.
- **"What This Consolidates":** add a **v3.14** row (multi-target, stateless lookback, single-walk
  generator, client registry).
- **Migration appendix:** v3.13 → v3.14 cutover — existing client becomes `CLIENT_ID=nas-a`;
  switch generator to multi-client; deprecate the global `sync-manifest.txt` path.

## 12. Open questions

None blocking. Concrete target count and per-target lookback values are deployment-time inputs
captured in the registry ConfigMap; the guide ships with placeholders (`nas-a`, `nas-c`, …) marked
`◄ MODIFY`.
