#!/usr/bin/env bash
set -euo pipefail

MACHINE_ID_FILE="/var/lib/your-os/machine-id"

log() {
  echo "$(date -Iseconds) [init-machine-id] $*"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing required binary: $1"
    exit 1
  }
}

require_bin uuidgen

mkdir -p "$(dirname "${MACHINE_ID_FILE}")"

if [[ -s "${MACHINE_ID_FILE}" ]]; then
  log "machine-id already present"
  exit 0
fi

machine_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
printf '%s\n' "${machine_id}" > "${MACHINE_ID_FILE}"
log "machine-id initialized: ${machine_id}"
