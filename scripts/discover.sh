#!/bin/bash
#
# Scan a workspace for Dockerfile / docker-compose base images and print any
# that aren't yet tracked in images.yaml, after filtering out known
# self-built/internal images (see config/exclude-patterns.txt).
#
# This does NOT write to images.yaml automatically -- deciding whether a
# newly found image is really a third-party dependency (vs. an internal
# image under a name that doesn't obviously look internal) needs a human
# to look at it once.
#
# Projects considered entirely out of scope for this sync (not self-built,
# just not something we track dependencies for) are skipped via
# config/ignore-paths.txt rather than filtered per-image.
#
# Usage: discover.sh [workspace_root]   (default: $HOME/workspace)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

WORKSPACE_ROOT="${1:-$HOME/workspace}"
IMAGES_MANIFEST="$ROOT_DIR/images.yaml"
EXCLUDE_FILE="$ROOT_DIR/config/exclude-patterns.txt"
IGNORE_PATHS_FILE="$ROOT_DIR/config/ignore-paths.txt"

require_cmd yq "Install mikefarah/yq v4: https://github.com/mikefarah/yq"
require_cmd find
require_cmd grep

require_local_config() {
  local file="$1"
  [[ -f "$file" ]] || die "$file not found. It's a local, checkout-specific file (gitignored) -- copy it from ${file}.sample and adjust for your workspace."
}

[[ -d "$WORKSPACE_ROOT" ]] || die "Workspace root not found: $WORKSPACE_ROOT"
[[ -f "$IMAGES_MANIFEST" ]] || die "Manifest not found: $IMAGES_MANIFEST"
require_local_config "$EXCLUDE_FILE"
require_local_config "$IGNORE_PATHS_FILE"

# --- load active exclude patterns (strip comments/blank lines) ------------
mapfile -t EXCLUDE_PATTERNS < <(grep -vE '^\s*(#|$)' "$EXCLUDE_FILE" 2>/dev/null || true)

is_excluded() {
  local ref="$1"
  local pattern
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    [[ "$ref" =~ $pattern ]] && return 0
  done
  return 1
}

# --- split an image ref into source + tag ("latest" if no tag given) -----
# Only looks at the path segment after the last "/" so a "host:port/..."
# registry prefix isn't mistaken for a tag separator. A leading "docker.io/"
# is stripped since it's the implicit default registry -- images.yaml never
# spells it out, so "docker.io/bitnami/mongodb" and "bitnami/mongodb" must
# compare as the same source.
split_ref() {
  local ref="$1" last_segment tag source
  last_segment="${ref##*/}"
  if [[ "$last_segment" == *:* ]]; then
    tag="${last_segment##*:}"
    source="${ref%:"$tag"}"
  else
    tag="latest"
    source="$ref"
  fi
  source="${source#docker.io/}"
  printf '%s|%s\n' "$source" "$tag"
}

# --- existing manifest entries, as a lookup set ---------------------------
EXISTING_SET="$(yq eval \
  '.categories[].images[] | (.source // .name) as $src | .tags[] as $tag | ($src + "|" + $tag)' \
  "$IMAGES_MANIFEST" | sort -u)"

already_tracked() {
  grep -qxF "$1" <<<"$EXISTING_SET"
}

# --- collect candidate Dockerfile / compose files -------------------------
mapfile -t IGNORE_PATHS < <(grep -vE '^\s*(#|$)' "$IGNORE_PATHS_FILE" 2>/dev/null || true)
IGNORE_PATH_ARGS=()
for p in "${IGNORE_PATHS[@]}"; do
  IGNORE_PATH_ARGS+=(-not -path "$p")
done

mapfile -t FILES < <(find "$WORKSPACE_ROOT" -type f \
  \( -iname 'Dockerfile*' -o -iname 'docker-compose*.yml' -o -iname 'docker-compose*.yaml' \
     -o -iname 'compose*.yml' -o -iname 'compose*.yaml' \) \
  -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/vendor/*' \
  -not -path '*/.git/*' -not -path '*/data.dev/*' \
  "${IGNORE_PATH_ARGS[@]}" \
  2>/dev/null | sort)

log_info "Scanning ${#FILES[@]} Dockerfile/compose file(s) under $WORKSPACE_ROOT..."

declare -A SEEN_CANDIDATES=()
CANDIDATE_COUNT=0

for f in "${FILES[@]}"; do
  case "$f" in
    */Dockerfile*)
      # Stage aliases ("FROM x AS build") don't count as real images when
      # referenced later by a subsequent "FROM build" line.
      declare -A stage_aliases=()
      while IFS= read -r line; do
        alias_name="$(echo "$line" | { grep -oiE '\bas\s+\S+\s*$' || true; } | awk '{print tolower($2)}')"
        [[ -n "$alias_name" ]] && stage_aliases["$alias_name"]=1
      done < <(grep -iE '^\s*FROM\s+' "$f")

      while IFS= read -r line; do
        ref="$(echo "$line" | sed -E 's/^\s*FROM\s+(--platform=[^ ]+\s+)?//I; s/\s+[Aa][Ss]\s+\S+\s*$//')"
        ref_lower="$(echo "$ref" | tr '[:upper:]' '[:lower:]')"
        [[ -n "${stage_aliases[$ref_lower]:-}" ]] && continue
        [[ -z "$ref" ]] && continue
        is_excluded "$ref" && continue

        key="$ref|$f"
        [[ -n "${SEEN_CANDIDATES[$key]:-}" ]] && continue

        norm="$(split_ref "$ref")"
        already_tracked "$norm" && continue

        SEEN_CANDIDATES["$key"]=1
        CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
        printf '%-55s  %s\n' "$ref" "$f"
      done < <(grep -iE '^\s*FROM\s+' "$f")
      unset stage_aliases
      ;;
    *)
      while IFS= read -r line; do
        ref="$(echo "$line" | sed -E 's/^\s*image:\s*//' | tr -d '"'"'"'')"
        [[ -z "$ref" ]] && continue
        # Unwrap a whole-value "${VAR:-default}" compose interpolation down
        # to its default, e.g. "${WORKER_IMAGE:-internal.registry/x:latest}".
        if [[ "$ref" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-(.+)\}$ ]]; then
          ref="${BASH_REMATCH[1]}"
        fi
        [[ -z "$ref" ]] && continue
        is_excluded "$ref" && continue

        key="$ref|$f"
        [[ -n "${SEEN_CANDIDATES[$key]:-}" ]] && continue

        norm="$(split_ref "$ref")"
        already_tracked "$norm" && continue

        SEEN_CANDIDATES["$key"]=1
        CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
        printf '%-55s  %s\n' "$ref" "$f"
      done < <(grep -iE '^\s*image:\s*' "$f")
      ;;
  esac
done

log_info "$CANDIDATE_COUNT candidate image(s) not yet in $IMAGES_MANIFEST (review and add manually)."
[[ "$CANDIDATE_COUNT" -eq 0 ]]
