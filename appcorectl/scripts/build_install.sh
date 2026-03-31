#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build.sh"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"

log() {
  printf '[install] %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage: scripts/build_install.sh [--system]

Options:
  --system  Install into /usr/local/bin/appcorectl

Environment:
  INSTALL_DIR  Override destination directory (default: ~/.local/bin)
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--system" ]]; then
  INSTALL_DIR="/usr/local/bin"
  shift
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -x "${BUILD_SCRIPT}" ]]; then
  chmod +x "${BUILD_SCRIPT}"
fi

"${BUILD_SCRIPT}"

mkdir -p "${INSTALL_DIR}"
install -m 0755 "${ROOT_DIR}/bin/appcorectl" "${INSTALL_DIR}/appcorectl"

log "installed to ${INSTALL_DIR}/appcorectl"
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  log "note: ${INSTALL_DIR} is not currently in PATH"
fi
