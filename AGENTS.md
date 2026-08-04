# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, etc.) when working with code in this repository. `CLAUDE.md` is a symlink to this file, so both stay in sync automatically — edit this one.

## What this repo does

Mirrors public middleware/base images (databases, cache, message queues, language runtimes) from overseas registries into a domestic registry, using GitHub Actions' outbound network access as the sync path (it can reach both sides; no dedicated sync infrastructure needed). This exists because Docker Hub and similar registries are sometimes rate-limited/blocked from mainland China. It only syncs third-party dependencies — never images we build and publish ourselves.

`images.yaml` is the single source of truth. Nothing else should need to change to add, remove, or retag a synced image.

## Commands

```bash
# Find images used across ~/workspace projects that aren't in images.yaml yet
./scripts/discover.sh [workspace_root]   # defaults to $HOME/workspace

# Run an actual sync (requires yq, curl, tar; see README for the yq caveat)
./scripts/sync.sh <registry> <registry_username> <registry_password> <repo>

# Syntax-check after editing a script
bash -n scripts/sync.sh
```

There is no build/lint/test suite — this is a small set of bash scripts plus a YAML manifest. Validate changes by running `discover.sh` against the real workspace (should report 0 candidates if `images.yaml` is complete) and/or a dry run of `sync.sh` against a throwaway registry host to inspect the generated `.sync-work/sync-images.yaml` mapping before it tries to push anywhere.

`config/exclude-patterns.txt` and `config/ignore-paths.txt` are gitignored local files (they name internal projects/registries) — only `.sample` copies are committed. Both `discover.sh` and `sync.sh` will fail with a clear error pointing at the `.sample` file if the local copy is missing; that's intentional, not a bug to "fix" by falling back to empty filters.

## Architecture

- **`images.yaml`** — categorized manifest (`runtime`/`database`/`cache`/`misc`). Each entry has `name` (target repo path — the source ref with only the leading registry *hostname* stripped, namespace/org kept, e.g. `ghcr.io/browserless/chromium` → `browserless/chromium`), optional `source` (full pull path; omit when `name` alone already resolves on docker.io, i.e. anything not hosted elsewhere), and `tags` (explicit list — this is not a full-repo sync). `name` must be globally unique; `sync.sh` fails fast on collisions.
- **`scripts/sync.sh`** — flattens `images.yaml` via `yq` (mikefarah's Go `yq eval` syntax — **not** the Debian/Ubuntu apt `yq` package, which is an unrelated Python/jq wrapper with incompatible syntax) into `source:tag -> target:tag` pairs, downloads a pinned [aliyun image-syncer](https://github.com/AliyunContainerService/image-syncer) release (version pinned at the top of the script), and runs it. All intermediate state (`auth.yaml` with a plaintext password, the mapping file, the `image-syncer` binary) lives under `.sync-work/`, which is gitignored. `download_image_syncer()` in `lib.sh` already skips downloading if the binary is present, which is what makes the CI cache step below effective — never extend that cache to the whole `.sync-work/` directory, since `auth.yaml` holds a plaintext registry password and a GitHub Actions cache is readable by anyone who can trigger a workflow run in the repo.
- **`scripts/discover.sh`** — scans Dockerfile/docker-compose files under a workspace root for base images not yet in `images.yaml`. Two-tier filtering, both driven by local config so adding a new internal project never requires a script change: `config/ignore-paths.txt` skips whole projects considered out of scope for this sync (not necessarily self-built — just not tracked here), `config/exclude-patterns.txt` filters individual self-built/internal image references by regex. It also unwraps whole-value compose `${VAR:-default}` interpolation and ignores Dockerfile `FROM` lines that reference an earlier build stage's alias rather than a real image. It never writes to `images.yaml` — new candidates are printed for manual review, since some names that look self-built aren't (and vice versa).
- **`.github/workflows/sync.yml`** — the actual sync only runs on `workflow_dispatch` or a push to `main` that touches `images.yaml`, `scripts/**`, or the workflow file itself (path-filtered — an unrelated push to `main`, e.g. a README change, does not trigger it). Needs four repo secrets: `REGISTRY`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`, `REPO`. Caches the `image-syncer` binary across runs via `actions/cache`, keyed off the version pinned in `scripts/sync.sh` (extracted with `grep`, not duplicated in the workflow) so a version bump busts the cache automatically. Image pull/push itself isn't and can't be cached this way — that traffic is inherent to the sync; `image-syncer` already skips pushing blobs the target already has.

## Working in this repo

- Keep everything (code, comments, YAML/config content, docs) in English — this was an explicit decision for the project.
- When changing the target-naming behavior in `sync.sh`, update the matching normalization in `discover.sh`'s `split_ref()` (it strips a leading `docker.io/` so raw refs and the manifest's implicit-source form compare equal) — the two have drifted out of sync before.
- `scripts/lib.sh` is sourced by both other scripts; put logging/download helpers shared between them there rather than duplicating.
