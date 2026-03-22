#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="/var/lib/your-os"
LAST_UPDATE_FILE="${RUNTIME_DIR}/last-update"
MIN_UPTIME_SECONDS=300

log() {
  echo "$(date -Iseconds) [update-os] $*"
}

uptime_seconds() {
  # /proc/uptime format: "<seconds> <idle-seconds>".
  awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0
}

current_uptime="$(uptime_seconds)"
if (( current_uptime < MIN_UPTIME_SECONDS )); then
  log "Skipping OS update: uptime ${current_uptime}s is below ${MIN_UPTIME_SECONDS}s guard."
  exit 0
fi

mkdir -p "${RUNTIME_DIR}"

log "Starting OS self-update."
# Placeholder until real bootc update flow is wired.
log "Simulating OS image pull (placeholder)."
touch "${LAST_UPDATE_FILE}"
log "Update marker written to ${LAST_UPDATE_FILE}."
log "Triggering reboot after update."
exec systemctl reboot
