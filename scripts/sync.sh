#!/bin/bash
#
# Sync the images listed in images.yaml from their upstream source into a
# local/private registry, using aliyun's image-syncer.
#
# Usage: sync.sh <registry> <registry_username> <registry_password> <repo>
#
# An optional secondary target can be configured with these environment
# variables: SECONDARY_REGISTRY, SECONDARY_REGISTRY_USERNAME,
# SECONDARY_REGISTRY_PASSWORD, and optionally SECONDARY_REPO (defaults to
# REPO). This keeps the original single-target CLI compatible while allowing
# one manifest sync to publish to two registries.
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
IMAGE_SYNCER_VERSION="v1.5.5"
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

SECONDARY_REGISTRY="${SECONDARY_REGISTRY:-}"
SECONDARY_REGISTRY_USERNAME="${SECONDARY_REGISTRY_USERNAME:-}"
SECONDARY_REGISTRY_PASSWORD="${SECONDARY_REGISTRY_PASSWORD:-}"
SECONDARY_REPO="${SECONDARY_REPO:-$REPO}"

if [[ -n "$SECONDARY_REGISTRY$SECONDARY_REGISTRY_USERNAME$SECONDARY_REGISTRY_PASSWORD" ]] \
  && [[ -z "$SECONDARY_REGISTRY" || -z "$SECONDARY_REGISTRY_USERNAME" || -z "$SECONDARY_REGISTRY_PASSWORD" ]]; then
  die "Secondary target requires SECONDARY_REGISTRY, SECONDARY_REGISTRY_USERNAME, and SECONDARY_REGISTRY_PASSWORD."
fi

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

# image-syncer expands $VAR/${VAR} expressions in auth files. Keep registry
# credentials out of the YAML itself: this is required for passwords that
# contain '$' and also avoids writing the plaintext password to disk.
export REGISTRY_SYNC_PRIMARY_USERNAME="$REGISTRY_USERNAME"
export REGISTRY_SYNC_PRIMARY_PASSWORD="$REGISTRY_PASSWORD"
if [[ -n "$SECONDARY_REGISTRY" ]]; then
  export REGISTRY_SYNC_SECONDARY_USERNAME="$SECONDARY_REGISTRY_USERNAME"
  export REGISTRY_SYNC_SECONDARY_PASSWORD="$SECONDARY_REGISTRY_PASSWORD"
fi

log_info "Writing auth config to $AUTH_FILE..."
printf '%s:\n  username: ${REGISTRY_SYNC_PRIMARY_USERNAME}\n  password: ${REGISTRY_SYNC_PRIMARY_PASSWORD}\n' \
  "$REGISTRY" >"$AUTH_FILE"

if [[ -n "$SECONDARY_REGISTRY" ]]; then
  printf '%s:\n  username: ${REGISTRY_SYNC_SECONDARY_USERNAME}\n  password: ${REGISTRY_SYNC_SECONDARY_PASSWORD}\n' \
    "$SECONDARY_REGISTRY" >>"$AUTH_FILE"
fi

log_info "Writing image-syncer mapping file to $SYNC_LIST_FILE..."
: >"$SYNC_LIST_FILE"
while IFS='|' read -r source tag name; do
  if [[ -n "$SECONDARY_REGISTRY" ]]; then
    printf '%s:%s:\n  - %s/%s/%s:%s\n  - %s/%s/%s:%s\n' \
      "$source" "$tag" \
      "$REGISTRY" "$REPO" "$name" "$tag" \
      "$SECONDARY_REGISTRY" "$SECONDARY_REPO" "$name" "$tag" \
      >>"$SYNC_LIST_FILE"
  else
    echo "${source}:${tag}: ${REGISTRY}/${REPO}/${name}:${tag}" >>"$SYNC_LIST_FILE"
  fi
done <<<"$MAPPING_LINES"

TARGET_SUMMARY="$REGISTRY/$REPO"
if [[ -n "$SECONDARY_REGISTRY" ]]; then
  TARGET_SUMMARY="$TARGET_SUMMARY and $SECONDARY_REGISTRY/$SECONDARY_REPO"
fi
log_info "Syncing $IMAGE_COUNT image(s) to $TARGET_SUMMARY..."
SYNC_LOG_FILE="$WORK_DIR/sync.log"

# image-syncer treats per-image failures as "best effort" and exits 0 even
# when every single task failed -- it only reports the tally in its own
# final log line. Capture that line and fail the script (and therefore the
# CI job) unless it says zero failures, so a broken sync can't silently
# report green.
set +e
"$IMAGE_SYNCER" --proc=20 --auth="$AUTH_FILE" --images="$SYNC_LIST_FILE" --retries=3 2>&1 | tee "$SYNC_LOG_FILE"
SYNC_EXIT="${PIPESTATUS[0]}"
set -e

[[ "$SYNC_EXIT" -eq 0 ]] || die "image-syncer exited with status $SYNC_EXIT"

SUMMARY_LINE="$(grep -E '(^Finished, [0-9]+ sync tasks failed, [0-9]+ tasks generate failed|Synchronization finished, [0-9]+ tasks failed)' "$SYNC_LOG_FILE" | tail -1)"
[[ -n "$SUMMARY_LINE" ]] || die "Could not find image-syncer's completion summary in the log -- treating as a failure."
[[ "$SUMMARY_LINE" =~ ^Finished,\ 0\ sync\ tasks\ failed,\ 0\ tasks\ generate\ failed || "$SUMMARY_LINE" =~ Synchronization\ finished,\ 0\ tasks\ failed ]] \
  || die "image-syncer reported failed task(s): $SUMMARY_LINE"

log_info "All $IMAGE_COUNT image(s) synced successfully."
