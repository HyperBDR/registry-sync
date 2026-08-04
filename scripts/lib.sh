#!/bin/bash
#
# Shared helpers for scripts/*.sh. Sourced, not executed directly.

log_info()  { echo "[INFO]  $*" >&2; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command '$cmd' not found in PATH.${hint:+ $hint}"
  fi
}

# Downloads a pinned image-syncer release into $1 (destination dir) if the
# binary isn't already there.
download_image_syncer() {
  local dest_dir="$1"
  local version="$2"
  local binary="$dest_dir/image-syncer"

  if [[ -x "$binary" ]]; then
    return 0
  fi

  local tarball="image-syncer-${version}-linux-amd64.tar.gz"
  local url="https://github.com/AliyunContainerService/image-syncer/releases/download/${version}/${tarball}"

  log_info "Downloading image-syncer ${version} from ${url}..."
  curl -fsSL -o "${dest_dir}/${tarball}" "$url"
  tar -zxf "${dest_dir}/${tarball}" -C "$dest_dir"
  rm -f "${dest_dir}/${tarball}"

  [[ -x "$binary" ]] || die "image-syncer binary not found after extracting ${tarball}"
}
