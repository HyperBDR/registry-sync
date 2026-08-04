# registry-sync

Syncs public middleware/base images (databases, cache, message queues, language runtimes) from overseas sources into our local mirror registry, to speed up internal pulls. It does **not** sync images we build and publish ourselves (devify, newshub, sourcelens, etc.) — only the third-party images we depend on.

## Layout

```
images.yaml                        The manifest (source of truth)
config/
  exclude-patterns.txt.sample      Template: rules discover.sh uses to filter out self-built/internal images
  ignore-paths.txt.sample          Template: workspace paths/projects discover.sh should skip entirely
scripts/
  lib.sh                           Shared helpers
  sync.sh                          Reads images.yaml and runs the sync
  discover.sh                      Scans workspace Dockerfile/compose files for images missing from the manifest
.github/workflows/sync.yml         CI: manual trigger / triggered on images.yaml changes
```

`config/exclude-patterns.txt` and `config/ignore-paths.txt` (no `.sample` suffix — what the scripts actually read) are gitignored: they name internal projects/registries and tend to get tweaked per checkout, so we don't want every local edit showing up as a diff. First-time setup:

```
cp config/exclude-patterns.txt.sample config/exclude-patterns.txt
cp config/ignore-paths.txt.sample config/ignore-paths.txt
```

Edit your local copies freely. If you add a rule that's broadly useful (not specific to your checkout), also update the `.sample` file and commit that.

## Adding an image to sync

Edit `images.yaml` directly and add an entry under the right category:

```yaml
- name: bitnami/mongodb   # target repo path: source ref with the registry hostname stripped, namespace kept
  tags: ["6.0"]           # `source` can be omitted here -- docker.io is the implicit default registry
```

```yaml
- name: browserless/chromium         # target repo path (no ghcr.io hostname)
  source: ghcr.io/browserless/chromium  # required: not on docker.io, so the pull host must be explicit
  tags: ["latest"]
```

The synced image lands at `{registry}/{repo}/{name}:{tag}` — only the source registry's hostname is dropped, the namespace/org stays: `bitnami/mongodb` lands at `.../bitnami/mongodb`, `instrumentisto/haraka` lands at `.../instrumentisto/haraka`, `ghcr.io/browserless/chromium` lands at `.../browserless/chromium`. `sync.sh` validates that every `name` is globally unique and fails fast on a collision.

No script changes needed — `images.yaml` is the only data source.

## Finding new images: discover.sh

```
./scripts/discover.sh [workspace_root]   # defaults to $HOME/workspace
```

Scans every `Dockerfile*` / `docker-compose*.yml` / `compose*.yml` under that directory for base images used, excluding:

- entire projects/paths matching `config/ignore-paths.txt` (out of scope for this sync — not necessarily self-built, just not something we track dependencies for)
- individual image references matching `config/exclude-patterns.txt` (internal registry domains/namespaces, known self-built product names)
- `FROM` lines in a Dockerfile that reference an earlier build stage's alias (not a real image)
- `source:tag` combinations already listed in `images.yaml`

What's left printed out is the set of new candidate images — review manually and add them to `images.yaml` yourself. **Nothing is auto-written** — some image names look self-built but aren't (e.g. a locally renamed `xxx-postgres`), so this needs a human judgment call.

Adding a new self-built project and don't want discover.sh to flag its images? Add a line to `config/exclude-patterns.txt`. Want to stop scanning a whole project (in scope or not)? Add its path to `config/ignore-paths.txt`. Neither needs a script change — but if you want the pattern to carry over to a fresh checkout, add it to the corresponding `.sample` file too.

## Running a sync: sync.sh

```
./scripts/sync.sh <registry> <registry_username> <registry_password> <repo>
```

Dependencies:
- [`yq`](https://github.com/mikefarah/yq) (mikefarah's Go version, `yq eval` syntax; GitHub Actions `ubuntu-latest` runners ship it by default. Locally, `brew install yq` or download the release binary. This is **not** the Debian/Ubuntu apt `yq` package, which is a Python/jq wrapper with incompatible syntax.)
- `curl`, `tar`

The script reads `images.yaml`, expands it per-tag into `source:tag -> target:tag` mappings, downloads/reuses [aliyun image-syncer](https://github.com/AliyunContainerService/image-syncer) (version pinned at the top of `scripts/sync.sh`), then runs the sync. Intermediate artifacts (`auth.yaml`, the mapping file, the image-syncer binary) all live under `.sync-work/` (already gitignored — it contains a plaintext password, never commit it).

## GitHub Actions

`.github/workflows/sync.yml`: manual trigger (`workflow_dispatch`), or automatically on a push to `main` that touches `images.yaml`/`scripts/**`. The scheduled run (`schedule`) is commented out — enable it once the desired cadence (e.g. weekly) is decided.

Configure these under repo Settings → Secrets:

| Secret | Description |
|---|---|
| `REGISTRY` | Target registry host, e.g. `registry.example.com` |
| `REGISTRY_USERNAME` | Target registry username |
| `REGISTRY_PASSWORD` | Target registry password |
| `REPO` | Namespace under the target registry, e.g. `mirror` |

If the target registry is only reachable from an internal network, GitHub's hosted runners won't be able to reach it — switch `runs-on: ubuntu-latest` to a [self-hosted runner](https://docs.github.com/actions/hosting-your-own-runners); everything else stays the same.
