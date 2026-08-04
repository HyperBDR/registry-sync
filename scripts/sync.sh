#!/bin/bash
#
# Sync the images listed in images.yaml from their upstream source into a
# local/private registry, using aliyun's image-syncer.
#
# Usage: sync.sh <registry> <registry_username> <registry_password> <repo>
#
#   registry           target registry host, e.g. registry.example.com
#   registry_username   target registry auth username
#   registry_password   target registry auth password
#   repo                target repo/namespace under the registry, e.g. mirror
#
# Every image in images.yaml lands at:
#   <registry>/<repo>/<name>:<tag>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

IMAGES_MANIFEST="$ROOT_DIR/images.yaml"
IMAGE_SYNCER_VERSION="v1.3.0"
WORK_DIR="$ROOT_DIR/.sync-work"

usage() {
  echo "Usage: $(basename "$0") <registry> <registry_username> <registry_password> <repo>" >&2
}

if [[ $# -ne 4 ]]; then
  usage
  exit 1
fi

REGISTRY="$1"
REGISTRY_USERNAME="$2"
REGISTRY_PASSWORD="$3"
REPO="$4"

require_cmd yq "Install mikefarah/yq v4: https://github.com/mikefarah/yq (GitHub Actions ubuntu-latest runners ship it by default)."
require_cmd curl
require_cmd tar

[[ -f "$IMAGES_MANIFEST" ]] || die "Manifest not found: $IMAGES_MANIFEST"

mkdir -p "$WORK_DIR"

# --- flatten images.yaml into "source|tag|name" lines --------------------
MAPPING_LINES="$(yq eval \
  '.categories[].images[] | (.source // .name) as $src | .tags[] as $tag | ($src + "|" + $tag + "|" + .name)' \
  "$IMAGES_MANIFEST")"

[[ -n "$MAPPING_LINES" ]] || die "No images found in $IMAGES_MANIFEST"

# --- fail fast on duplicate target names -----------------------------------
# (a name is only a real duplicate if two *different* sources claim it --
# the same image with multiple tags legitimately repeats its name/source)
UNIQUE_SOURCE_NAME_PAIRS="$(echo "$MAPPING_LINES" | cut -d'|' -f1,3 --output-delimiter='|' | sort -u)"
DUPLICATES="$(echo "$UNIQUE_SOURCE_NAME_PAIRS" | cut -d'|' -f2 | sort | uniq -d)"
if [[ -n "$DUPLICATES" ]]; then
  die "Duplicate target image name(s) in $IMAGES_MANIFEST (target repo path must be unique): $(echo "$DUPLICATES" | tr '\n' ' ')"
fi

IMAGE_COUNT="$(echo "$MAPPING_LINES" | wc -l | tr -d ' ')"
log_info "Loaded $IMAGE_COUNT image:tag entries from $IMAGES_MANIFEST"

# --- image-syncer setup ----------------------------------------------------
download_image_syncer "$WORK_DIR" "$IMAGE_SYNCER_VERSION"
IMAGE_SYNCER="$WORK_DIR/image-syncer"

AUTH_FILE="$WORK_DIR/auth.yaml"
SYNC_LIST_FILE="$WORK_DIR/sync-images.yaml"

log_info "Writing auth config to $AUTH_FILE..."
cat >"$AUTH_FILE" <<EOF
$REGISTRY:
  username: $REGISTRY_USERNAME
  password: $REGISTRY_PASSWORD
EOF

log_info "Writing image-syncer mapping file to $SYNC_LIST_FILE..."
: >"$SYNC_LIST_FILE"
while IFS='|' read -r source tag name; do
  echo "${source}:${tag}: ${REGISTRY}/${REPO}/${name}:${tag}" >>"$SYNC_LIST_FILE"
done <<<"$MAPPING_LINES"

log_info "Syncing $IMAGE_COUNT image(s) to $REGISTRY/$REPO..."
"$IMAGE_SYNCER" --proc=20 --auth="$AUTH_FILE" --images="$SYNC_LIST_FILE" --retries=3
