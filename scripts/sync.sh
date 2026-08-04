#!/bin/bash
#
# Sync the images listed in images.yaml from their upstream source into one or
# two registries, using regclient's regsync.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

IMAGES_MANIFEST="$ROOT_DIR/images.yaml"
REGSYNC_VERSION="v0.11.5"
WORK_DIR="$ROOT_DIR/.sync-work"

usage() { echo "Usage: $(basename "$0") <registry> <registry_username> <registry_password> <repo>" >&2; }
if [[ $# -ne 4 ]]; then usage; exit 1; fi

REGISTRY="$1"
REGISTRY_USERNAME="$2"
REGISTRY_PASSWORD="$3"
REPO="$4"
SECONDARY_REGISTRY="${SECONDARY_REGISTRY:-}"
SECONDARY_REGISTRY_USERNAME="${SECONDARY_REGISTRY_USERNAME:-}"
SECONDARY_REGISTRY_PASSWORD="${SECONDARY_REGISTRY_PASSWORD:-}"
SECONDARY_REPO="${SECONDARY_REPO:-$REPO}"

if [[ -n "$SECONDARY_REGISTRY$SECONDARY_REGISTRY_USERNAME$SECONDARY_REGISTRY_PASSWORD" ]] \
  && [[ -z "$SECONDARY_REGISTRY" || -z "$SECONDARY_REGISTRY_USERNAME" || -z "$SECONDARY_REGISTRY_PASSWORD" ]]; then
  die "Secondary target requires SECONDARY_REGISTRY, SECONDARY_REGISTRY_USERNAME, and SECONDARY_REGISTRY_PASSWORD."
fi

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
CONFIG_FILE="$WORK_DIR/regsync.yml"

DOCKER_CONFIG_DIR="$(mktemp -d)"
cleanup() { rm -rf "$DOCKER_CONFIG_DIR"; }
trap cleanup EXIT

write_docker_auth() {
  local registry="$1" username="$2" password="$3" encoded
  encoded="$(printf '%s:%s' "$username" "$password" | base64 -w0)"
  if [[ ! -f "$DOCKER_CONFIG_DIR/config.json" ]]; then
    printf '{"auths":{}}\n' >"$DOCKER_CONFIG_DIR/config.json"
  fi
  python3 - "$DOCKER_CONFIG_DIR/config.json" "$registry" "$encoded" <<'PY'
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

write_docker_auth "$REGISTRY" "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD"
if [[ -n "$SECONDARY_REGISTRY" ]]; then
  write_docker_auth "$SECONDARY_REGISTRY" "$SECONDARY_REGISTRY_USERNAME" "$SECONDARY_REGISTRY_PASSWORD"
fi
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

printf '%s\n' 'version: 1' 'defaults:' '  parallel: 10' '  skipDockerConfig: false' 'sync:' >"$CONFIG_FILE"
while IFS='|' read -r source tag name; do
  printf '  - source: %s:%s\n    target: %s/%s/%s:%s\n    type: image\n' \
    "$source" "$tag" "$REGISTRY" "$REPO" "$name" "$tag" >>"$CONFIG_FILE"
  if [[ -n "$SECONDARY_REGISTRY" ]]; then
    printf '  - source: %s:%s\n    target: %s/%s/%s:%s\n    type: image\n' \
      "$source" "$tag" "$SECONDARY_REGISTRY" "$SECONDARY_REPO" "$name" "$tag" >>"$CONFIG_FILE"
  fi
done <<<"$MAPPING_LINES"

TARGET_SUMMARY="$REGISTRY/$REPO"
if [[ -n "$SECONDARY_REGISTRY" ]]; then TARGET_SUMMARY="$TARGET_SUMMARY and $SECONDARY_REGISTRY/$SECONDARY_REPO"; fi
log_info "Syncing $IMAGE_COUNT image(s) to $TARGET_SUMMARY with regsync $REGSYNC_VERSION..."
"$REGSYNC" -c "$CONFIG_FILE" once --logopt text
log_info "All $IMAGE_COUNT image(s) synced successfully."
