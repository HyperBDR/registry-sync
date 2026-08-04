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

# Downloads a pinned regsync release into $1 (destination dir) if the binary
# isn't already there.
download_regsync() {
  local dest_dir="$1"
  local version="$2"
  local binary="$dest_dir/regsync"

  if [[ -x "$binary" ]]; then
    return 0
  fi

  local archive="regsync-linux-amd64"
  local url="https://github.com/regclient/regclient/releases/download/${version}/${archive}"

  log_info "Downloading regsync ${version} from ${url}..."
  curl -fsSL -o "$binary" "$url"
  chmod 755 "$binary"

  [[ -x "$binary" ]] || die "regsync binary not found after downloading ${archive}"
}
