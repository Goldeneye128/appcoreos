#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/lib/your-os/state.json"
SLEEP_SECONDS=30

log() {
  echo "$(date -Iseconds) [agent] $*"
}

while true; do
  if [[ ! -f "${STATE_FILE}" ]]; then
    log "state file missing at ${STATE_FILE}"
    sleep "${SLEEP_SECONDS}"
    continue
  fi

  hostname_value="$(yq -r '.hostname // "unknown"' "${STATE_FILE}" 2>/dev/null || echo "unknown")"
  container_count="$(yq -r '.containers // [] | length' "${STATE_FILE}" 2>/dev/null || echo "0")"

  log "hostname=${hostname_value} containers=${container_count}"
  sleep "${SLEEP_SECONDS}"
done
