# registry-sync

Syncs public middleware/base images (databases, cache, message queues, language runtimes) from overseas sources into our local mirror registry, to speed up internal pulls. It does **not** sync images we build and publish ourselves (devify, newshub, sourcelens, etc.) — only the third-party images we depend on.

## Why

Docker Hub and other overseas registries are sometimes rate-limited, blocked, or slow from mainland China. That gets in the way of a smooth deployment/onboarding experience for our products, so we mirror the public images we depend on into a domestic registry.

The idea (and the general approach) is borrowed from other projects doing the same thing: use GitHub Actions' outbound network access — which can reach both the overseas source registries and our domestic target registry — to pull an image from upstream and push it straight to the mirror, without ever routing image data through a machine inside mainland China. Repeated on a schedule/on demand, this gives us a self-updating container image mirror with no dedicated sync infrastructure to run ourselves.

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
- name: bitnami/mongodb   # source-derived mirror name; target uses mongodb
  tags: ["6.0"]           # `source` can be omitted here -- docker.io is the implicit default registry
```

```yaml
- name: browserless/chromium         # target uses chromium (no ghcr.io hostname)
  source: ghcr.io/browserless/chromium  # required: not on docker.io, so the pull host must be explicit
  tags: ["latest"]
```

The synced image lands at `{registry}/{repo}/{target-name}:{tag}`. The source registry hostname and all path prefixes are dropped because the Aliyun namespaces only permit a single repository path segment: `bitnami/mongodb` lands at `.../mongodb`, `instrumentisto/haraka` lands at `.../haraka`, and `ghcr.io/browserless/chromium` lands at `.../chromium`. `sync.sh` validates that target names are collision-free.

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

The GitHub Actions workflow mirrors to two Aliyun namespaces. Its project-level
configuration uses this naming convention:

```text
REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_HOST
REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_REPO
REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_USERNAME
REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_PASSWORD
REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_HOST
REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_REPO
REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_USERNAME
REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_PASSWORD
```

Use project Variables for `HOST` and `REPO`, and project Secrets for `USERNAME`
and `PASSWORD`. Running `sync.sh` without arguments reads these names directly;
the four-argument form remains available for a single local target.

Credentials are written to a temporary `regsync` config and removed when the
script exits. The config prefers monolithic blob uploads for Aliyun; regsync
can still fall back to chunked uploads when a monolithic upload fails.

Dependencies:
- [`yq`](https://github.com/mikefarah/yq) (mikefarah's Go version, `yq eval` syntax; GitHub Actions `ubuntu-latest` runners ship it by default. Locally, `brew install yq` or download the release binary. This is **not** the Debian/Ubuntu apt `yq` package, which is a Python/jq wrapper with incompatible syntax.)
- `curl`

The script reads `images.yaml`, expands it into `regsync` image entries, and
runs `regsync once`. GitHub Actions installs `regsync` with the official
[`regclient/actions/regsync-installer`](https://github.com/regclient/actions)
action; local runs use the same binary when available and otherwise download
the pinned release. Any failed sync entry makes the job fail.

The previous image-syncer experiment was retired after repeated task failures. `bitnami/mongodb:6.0` was also dropped from `images.yaml` since Bitnami discontinued that free versioned tag on Docker Hub (see `images.yaml`'s comment there and `AGENTS.md` for the follow-up needed on the `income` project's own `docker-compose.yml`, which pulls the same now-broken tag).

## GitHub Actions

`.github/workflows/sync.yml`: manual trigger (`workflow_dispatch`), or automatically on a push to `main` that touches `images.yaml`/`scripts/**`. The scheduled run (`schedule`) is commented out — enable it once the desired cadence (e.g. weekly) is decided.

Configure these under repo Settings → Secrets:

| Secret | Description |
|---|---|
| `REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_HOST` | Project Variable for the first Aliyun registry host |
| `REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_REPO` | Project Variable for the first Aliyun namespace |
| `REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_USERNAME` | Project Secret for the first Aliyun username |
| `REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_PASSWORD` | Project Secret for the first Aliyun password |
| `REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_HOST` | Project Variable for the second Aliyun registry host |
| `REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_REPO` | Project Variable for the second Aliyun namespace |
| `REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_USERNAME` | Project Secret for the second Aliyun username |
| `REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_PASSWORD` | Project Secret for the second Aliyun password |

If the target registry is only reachable from an internal network, GitHub's hosted runners won't be able to reach it — switch `runs-on: ubuntu-latest` to a [self-hosted runner](https://docs.github.com/actions/hosting-your-own-runners); everything else stays the same.
