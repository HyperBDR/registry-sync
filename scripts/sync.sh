#!/bin/bash
#
# Sync the images listed in images.yaml from their upstream source into one or
# two registries. Most images use regclient's regsync; images listed in the
# Skopeo fallback file use skopeo copy. With no arguments, registry settings
# are read from the organization-wide REGISTRY_* variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

IMAGES_MANIFEST="$ROOT_DIR/images.yaml"
SKOPEO_FALLBACK_FILE="$ROOT_DIR/config/skopeo-fallback-images.txt"
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
[[ -f "$IMAGES_MANIFEST" ]] || die "Manifest not found: $IMAGES_MANIFEST"
[[ -f "$SKOPEO_FALLBACK_FILE" ]] || die "Skopeo fallback list not found: $SKOPEO_FALLBACK_FILE"
mkdir -p "$WORK_DIR"

MAPPING_LINES="$(yq eval \
  '.categories[].images[] | (.source // .name) as $src | .tags[] as $tag | ($src + "|" + $tag + "|" + .name)' \
  "$IMAGES_MANIFEST")"
[[ -n "$MAPPING_LINES" ]] || die "No images found in $IMAGES_MANIFEST"

declare -A FALLBACK_IMAGES=()
while IFS= read -r fallback_name || [[ -n "$fallback_name" ]]; do
  fallback_name="${fallback_name%%#*}"
  fallback_name="${fallback_name//[[:space:]]/}"
  [[ -n "$fallback_name" ]] || continue
  FALLBACK_IMAGES["$fallback_name"]=1
done <"$SKOPEO_FALLBACK_FILE"

declare -A MANIFEST_IMAGES=()
while IFS='|' read -r _source _tag name; do
  MANIFEST_IMAGES["$name"]=1
done <<<"$MAPPING_LINES"
for fallback_name in "${!FALLBACK_IMAGES[@]}"; do
  [[ -n "${MANIFEST_IMAGES[$fallback_name]:-}" ]] \
    || die "Skopeo fallback image is not listed in $IMAGES_MANIFEST: $fallback_name"
done

NORMAL_MAPPING_LINES=""
FALLBACK_MAPPING_LINES=""
while IFS='|' read -r source tag name; do
  if [[ -n "${FALLBACK_IMAGES[$name]:-}" ]]; then
    FALLBACK_MAPPING_LINES+="${source}|${tag}|${name}"$'\n'
  else
    NORMAL_MAPPING_LINES+="${source}|${tag}|${name}"$'\n'
  fi
done <<<"$MAPPING_LINES"

UNIQUE_SOURCE_NAME_PAIRS="$(while IFS='|' read -r source _tag name; do
  printf '%s|%s\n' "$source" "${name##*/}"
done <<<"$MAPPING_LINES" | sort -u)"
DUPLICATES="$(echo "$UNIQUE_SOURCE_NAME_PAIRS" | cut -d'|' -f2 | sort | uniq -d)"
if [[ -n "$DUPLICATES" ]]; then
  die "Duplicate target image name(s) in $IMAGES_MANIFEST: $(echo "$DUPLICATES" | tr '\n' ' ')"
fi

IMAGE_COUNT="$(echo "$MAPPING_LINES" | wc -l | tr -d ' ')"
NORMAL_IMAGE_COUNT="$(printf '%s' "$NORMAL_MAPPING_LINES" | sed '/^$/d' | wc -l | tr -d ' ')"
FALLBACK_IMAGE_COUNT="$(printf '%s' "$FALLBACK_MAPPING_LINES" | sed '/^$/d' | wc -l | tr -d ' ')"
log_info "Loaded $IMAGE_COUNT image:tag entries from $IMAGES_MANIFEST"
if [[ "$NORMAL_IMAGE_COUNT" -gt 0 ]]; then
  if command -v regsync >/dev/null 2>&1; then
    REGSYNC="$(command -v regsync)"
  else
    download_regsync "$WORK_DIR" "$REGSYNC_VERSION"
    REGSYNC="$WORK_DIR/regsync"
  fi
fi
if [[ "$FALLBACK_IMAGE_COUNT" -gt 0 ]]; then
  require_cmd skopeo "Install skopeo: https://github.com/containers/skopeo"
fi
TEMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

for index in "${!TARGET_REGISTRIES[@]}"; do
  registry="${TARGET_REGISTRIES[$index]}"
  username="${TARGET_USERNAMES[$index]}"
  password="${TARGET_PASSWORDS[$index]}"
  repo="${TARGET_REPOS[$index]}"
  run_dir="$TEMP_DIR/$index"
  config_file="$run_dir/regsync.yml"
  auth_file="$run_dir/skopeo-auth.json"
  mkdir -p "$run_dir"

  if [[ "$NORMAL_IMAGE_COUNT" -gt 0 ]]; then
    printf '%s\n' \
      'version: 1' \
      'creds:' \
      "  - registry: $(yaml_quote "$registry")" \
      "    user: $(yaml_quote "$username")" \
      "    pass: $(yaml_quote "$password")" \
      '    blobMax: -1' \
      'defaults:' \
      '  parallel: 10' \
      '  skipDockerConfig: true' \
      'sync:' >"$config_file"
    while IFS='|' read -r source tag name; do
      [[ -n "$source" ]] || continue
      target_name="${name##*/}"
      printf '  - source: %s:%s\n    target: %s/%s/%s:%s\n    type: image\n' \
        "$source" "$tag" "$registry" "$repo" "$target_name" "$tag" >>"$config_file"
    done <<<"$NORMAL_MAPPING_LINES"

    log_info "Syncing $NORMAL_IMAGE_COUNT regular image(s) to $registry/$repo with regsync $REGSYNC_VERSION..."
    "$REGSYNC" -c "$config_file" once --logopt text
  fi

  if [[ "$FALLBACK_IMAGE_COUNT" -gt 0 ]]; then
    printf '%s' "$password" | skopeo login --authfile "$auth_file" --username "$username" --password-stdin "$registry"
    while IFS='|' read -r source tag name; do
      [[ -n "$source" ]] || continue
      target_name="${name##*/}"
      log_info "Syncing fallback image $source:$tag to $registry/$repo/$target_name:$tag with skopeo..."
      skopeo copy --all --retry-times 3 --dest-authfile "$auth_file" \
        "docker://$source:$tag" "docker://$registry/$repo/$target_name:$tag"
    done <<<"$FALLBACK_MAPPING_LINES"
  fi
done

log_info "All $IMAGE_COUNT image(s) synced successfully to ${#TARGET_REGISTRIES[@]} target(s)."
