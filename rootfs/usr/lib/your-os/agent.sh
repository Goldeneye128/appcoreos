#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/lib/your-os/state.json"
CONFIG_FILE="/var/lib/your-os/config.yaml"
CONFIG_NEW_FILE="/var/lib/your-os/config.new.yaml"
MACHINE_ID_FILE="/var/lib/your-os/machine-id"
REMOTE_CONFIG_BASE_URL="http://127.0.0.1:8081/config"
SLEEP_SECONDS=30

log() {
  echo "$(date -Iseconds) [agent] $*"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing required binary: $1"
    exit 1
  }
}

require_bin yq
require_bin curl
require_bin systemctl

if [[ ! -s "${MACHINE_ID_FILE}" ]]; then
  log "machine-id missing at ${MACHINE_ID_FILE}"
  exit 1
fi

machine_id="$(tr -d '\n' < "${MACHINE_ID_FILE}")"
remote_config_url="${REMOTE_CONFIG_BASE_URL}/${machine_id}"
log "machine-id=${machine_id}"

while true; do
  if [[ ! -f "${STATE_FILE}" ]]; then
    log "state file missing at ${STATE_FILE}"
  else
    hostname_value="$(yq -r '.hostname // "unknown"' "${STATE_FILE}" 2>/dev/null || echo "unknown")"
    container_count="$(yq -r '.containers // [] | length' "${STATE_FILE}" 2>/dev/null || echo "0")"
    log "hostname=${hostname_value} containers=${container_count}"
  fi

  log "fetching remote config from ${remote_config_url}"
  rm -f "${CONFIG_NEW_FILE}"
  http_code="$(
    curl -sS --max-time 10 --output "${CONFIG_NEW_FILE}" --write-out "%{http_code}" \
      "${remote_config_url}" 2>/dev/null || true
  )"

  if [[ "${http_code}" == "200" ]]; then
    log "remote config fetch succeeded (HTTP 200)"
    if ! yq -e '.' "${CONFIG_NEW_FILE}" >/dev/null 2>&1; then
      log "remote config invalid, ignoring"
      rm -f "${CONFIG_NEW_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    if [[ -f "${CONFIG_FILE}" ]] && cmp -s "${CONFIG_NEW_FILE}" "${CONFIG_FILE}"; then
      log "remote config unchanged"
      rm -f "${CONFIG_NEW_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    mv -f "${CONFIG_NEW_FILE}" "${CONFIG_FILE}"
    log "config updated from remote"
    log "triggering reboot due to config change"
    exec systemctl reboot
  else
    log "remote config fetch skipped (HTTP ${http_code:-error})"
  fi

  sleep "${SLEEP_SECONDS}"
done
