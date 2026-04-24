#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="${ROOT_DIR}/bin/appcorectl"

log() {
  printf '[build] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[build] ERROR: required command not found: $1" >&2
    exit 1
  fi
}

main() {
  require_cmd cargo
  mkdir -p "${ROOT_DIR}/bin"

  log "building Rust CLI with cargo"
  (
    cd "${ROOT_DIR}"
    cargo build --release --locked
  )

  install -m 0755 "${ROOT_DIR}/target/release/appcorectl" "${BIN_PATH}"
  log "running smoke test"
  "${BIN_PATH}" --help >/dev/null
  log "build succeeded: ${BIN_PATH}"
}

main "$@"
