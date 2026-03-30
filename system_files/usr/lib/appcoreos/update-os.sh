#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "$(date -Iseconds) [update-os] $*"
}

STAMP_DIR="/var/lib/appcoreos"
LAST_CHECK_FILE="${STAMP_DIR}/last-update-check"

mkdir -p "${STAMP_DIR}"

log "starting host update stage"

# Use Fedora CoreOS/bootc native update service when available.
if systemctl list-unit-files --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "bootc-fetch-apply-updates.service"; then
  if systemctl start bootc-fetch-apply-updates.service; then
    date -Iseconds > "${LAST_CHECK_FILE}"
    log "bootc update stage finished"
    exit 0
  fi
  log "bootc-fetch-apply-updates.service failed"
fi

# Fallback path for environments where the bootc unit is missing.
if command -v bootc >/dev/null 2>&1; then
  if bootc upgrade; then
    date -Iseconds > "${LAST_CHECK_FILE}"
    log "bootc upgrade finished"
    exit 0
  fi
fi

log "no update method succeeded"
exit 1
