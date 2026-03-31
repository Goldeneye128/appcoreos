#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_DIR="/var/lib/appcoreos/bootstrap"
BOOTSTRAP_TOKEN_FILE="${BOOTSTRAP_DIR}/token"
BOOTSTRAP_CLAIMED_FILE="${BOOTSTRAP_DIR}/claimed"
PKI_DIR="/var/lib/appcoreos/pki"
CLIENT_CA_FILE="${PKI_DIR}/client-ca.crt"

log() {
  echo "$(date -Iseconds) [init-bootstrap] $*"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing required binary: $1"
    exit 1
  }
}

require_bin openssl

mkdir -p "${BOOTSTRAP_DIR}" "${PKI_DIR}"
chmod 0700 "${BOOTSTRAP_DIR}" "${PKI_DIR}" || true

if [[ ! -s "${BOOTSTRAP_TOKEN_FILE}" ]]; then
  umask 077
  openssl rand -hex 16 > "${BOOTSTRAP_TOKEN_FILE}"
  log "bootstrap token initialized"
else
  log "bootstrap token already present"
fi

chmod 0600 "${BOOTSTRAP_TOKEN_FILE}" || true

if [[ -f "${BOOTSTRAP_CLAIMED_FILE}" ]]; then
  log "node is already claimed"
else
  log "node is unclaimed"
fi

if [[ -s "${CLIENT_CA_FILE}" ]]; then
  log "client CA is present"
fi
