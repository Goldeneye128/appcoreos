#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="${ROOT_DIR}/bin/appcorectl-linux-amd64"
TARGET_TRIPLE="x86_64-unknown-linux-gnu"

log() {
  printf '[build-linux-amd64] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[build-linux-amd64] ERROR: required command not found: $1" >&2
    exit 1
  fi
}

build_with_host_zig() {
  require_cmd cargo-zigbuild
  require_cmd zig
  require_cmd rustup

  rustup target add "${TARGET_TRIPLE}"
  (
    cd "${ROOT_DIR}"
    cargo zigbuild --release --locked --target "${TARGET_TRIPLE}"
  )
}

build_with_nix_zig() {
  require_cmd nix

  nix shell nixpkgs#zig --command bash -lc "
    set -euo pipefail
    export PATH=\"${HOME}/.cargo/bin:\$PATH\"
    rustup target add ${TARGET_TRIPLE}
    cargo-zigbuild --version >/dev/null 2>&1
    cd '${ROOT_DIR}'
    cargo zigbuild --release --locked --target '${TARGET_TRIPLE}'
  "
}

main() {
  mkdir -p "${ROOT_DIR}/bin"

  if command -v zig >/dev/null 2>&1; then
    log "building Linux/amd64 CLI with host zig"
    build_with_host_zig
  else
    log "building Linux/amd64 CLI with nix-provided zig"
    build_with_nix_zig
  fi

  install -m 0755 "${ROOT_DIR}/target/${TARGET_TRIPLE}/release/appcorectl" "${BIN_PATH}"
  file "${BIN_PATH}"
  log "build succeeded: ${BIN_PATH}"
}

main "$@"
