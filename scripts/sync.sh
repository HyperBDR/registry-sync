#!/bin/bash
#
# Sync the images listed in images.yaml from their upstream source into one or
# two registries, using regclient's regsync. With no arguments, registry
# settings are read from the organization-wide REGISTRY_* variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

IMAGES_MANIFEST="$ROOT_DIR/images.yaml"
REGSYNC_VERSION="v0.11.5"
WORK_DIR="$ROOT_DIR/.sync-work"

usage() { echo "Usage: $(basename "$0") [<registry> <registry_username> <registry_password> <repo>]" >&2; }
if [[ $# -ne 0 && $# -ne 4 ]]; then usage; exit 1; fi

if [[ $# -eq 4 ]]; then
  REGISTRY="$1"
  REGISTRY_USERNAME="$2"
  REGISTRY_PASSWORD="$3"
  REPO="$4"
  TARGET_REGISTRIES=("$REGISTRY")
  TARGET_USERNAMES=("$REGISTRY_USERNAME")
  TARGET_PASSWORDS=("$REGISTRY_PASSWORD")
  TARGET_REPOS=("$REPO")
else
  TARGET_REGISTRIES=(
    "${REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_HOST:-}"
    "${REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_HOST:-}"
  )
  TARGET_USERNAMES=(
    "${REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_USERNAME:-}"
    "${REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_USERNAME:-}"
  )
  TARGET_PASSWORDS=(
    "${REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_PASSWORD:-}"
    "${REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_PASSWORD:-}"
  )
  TARGET_REPOS=(
    "${REGISTRY_ALIYUN_CN_BEIJING_ONEPROLABS_REPO:-}"
    "${REGISTRY_ALIYUN_CN_BEIJING_CLOUD2AI_REPO:-}"
  )
fi

for index in "${!TARGET_REGISTRIES[@]}"; do
  [[ -n "${TARGET_REGISTRIES[$index]}" && -n "${TARGET_USERNAMES[$index]}" && -n "${TARGET_PASSWORDS[$index]}" && -n "${TARGET_REPOS[$index]}" ]] \
    || die "Target registry configuration is incomplete at index $index."
done

require_cmd yq "Install mikefarah/yq v4: https://github.com/mikefarah/yq"
require_cmd curl
require_cmd base64
require_cmd python3
[[ -f "$IMAGES_MANIFEST" ]] || die "Manifest not found: $IMAGES_MANIFEST"
mkdir -p "$WORK_DIR"

MAPPING_LINES="$(yq eval \
  '.categories[].images[] | (.source // .name) as $src | .tags[] as $tag | ($src + "|" + $tag + "|" + .name)' \
  "$IMAGES_MANIFEST")"
[[ -n "$MAPPING_LINES" ]] || die "No images found in $IMAGES_MANIFEST"

UNIQUE_SOURCE_NAME_PAIRS="$(echo "$MAPPING_LINES" | cut -d'|' -f1,3 --output-delimiter='|' | sort -u)"
DUPLICATES="$(echo "$UNIQUE_SOURCE_NAME_PAIRS" | cut -d'|' -f2 | sort | uniq -d)"
if [[ -n "$DUPLICATES" ]]; then
  die "Duplicate target image name(s) in $IMAGES_MANIFEST: $(echo "$DUPLICATES" | tr '\n' ' ')"
fi

IMAGE_COUNT="$(echo "$MAPPING_LINES" | wc -l | tr -d ' ')"
log_info "Loaded $IMAGE_COUNT image:tag entries from $IMAGES_MANIFEST"
if command -v regsync >/dev/null 2>&1; then
  REGSYNC="$(command -v regsync)"
else
  download_regsync "$WORK_DIR" "$REGSYNC_VERSION"
  REGSYNC="$WORK_DIR/regsync"
fi
TEMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

write_docker_auth() {
  local config_dir="$1" registry="$2" username="$3" password="$4" encoded
  encoded="$(printf '%s:%s' "$username" "$password" | base64 -w0)"
  if [[ ! -f "$config_dir/config.json" ]]; then
    printf '{"auths":{}}\n' >"$config_dir/config.json"
  fi
  python3 - "$config_dir/config.json" "$registry" "$encoded" <<'PY'
import json
import sys
path, registry, encoded = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data.setdefault("auths", {})[registry] = {"auth": encoded}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
    handle.write("\n")
PY
}

for index in "${!TARGET_REGISTRIES[@]}"; do
  registry="${TARGET_REGISTRIES[$index]}"
  username="${TARGET_USERNAMES[$index]}"
  password="${TARGET_PASSWORDS[$index]}"
  repo="${TARGET_REPOS[$index]}"
  run_dir="$TEMP_DIR/$index"
  docker_config_dir="$run_dir/.docker"
  config_file="$run_dir/regsync.yml"
  mkdir -p "$docker_config_dir"
  write_docker_auth "$docker_config_dir" "$registry" "$username" "$password"

  printf '%s\n' 'version: 1' 'defaults:' '  parallel: 10' '  skipDockerConfig: false' 'sync:' >"$config_file"
  while IFS='|' read -r source tag name; do
    printf '  - source: %s:%s\n    target: %s/%s/%s:%s\n    type: image\n' \
      "$source" "$tag" "$registry" "$repo" "$name" "$tag" >>"$config_file"
  done <<<"$MAPPING_LINES"

  log_info "Syncing $IMAGE_COUNT image(s) to $registry/$repo with regsync $REGSYNC_VERSION..."
  HOME="$run_dir" DOCKER_CONFIG="$docker_config_dir" "$REGSYNC" -c "$config_file" once --logopt text
done

log_info "All $IMAGE_COUNT image(s) synced successfully to ${#TARGET_REGISTRIES[@]} target(s)."
