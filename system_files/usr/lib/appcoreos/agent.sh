#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/lib/appcoreos/state.json"
CONFIG_FILE="/var/lib/appcoreos/config.yaml"
CONFIG_NEW_FILE="/var/lib/appcoreos/config.new.yaml"
CONFIG_DOWNLOAD_FILE="/var/lib/appcoreos/config.new.yaml.download"
LAST_REBOOT_TRIGGER_FILE="/var/lib/appcoreos/last-reboot-trigger"
MACHINE_ID_FILE="/var/lib/appcoreos/machine-id"
REMOTE_CONFIG_BASE_URL="http://10.0.2.2:8081/config"
DEBUG_SERVER_SCRIPT="/usr/lib/appcoreos/agent-debug-server.py"
MAX_CONFIG_BYTES=1048576
MIN_REBOOT_INTERVAL_SECONDS=60
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
require_bin cmp
require_bin mktemp
require_bin python3

if [[ ! -s "${MACHINE_ID_FILE}" ]]; then
  log "machine-id missing at ${MACHINE_ID_FILE}"
  exit 1
fi

machine_id="$(tr -d '\n' < "${MACHINE_ID_FILE}")"
remote_config_url="${REMOTE_CONFIG_BASE_URL}/${machine_id}"
log "machine-id=${machine_id}"

if [[ ! -f "${DEBUG_SERVER_SCRIPT}" ]]; then
  log "debug server missing at ${DEBUG_SERVER_SCRIPT}"
  exit 1
fi

log "starting local debug HTTP server on 127.0.0.1:9090"
python3 "${DEBUG_SERVER_SCRIPT}" &
debug_server_pid="$!"

cleanup() {
  if [[ -n "${debug_server_pid:-}" ]]; then
    kill "${debug_server_pid}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

while true; do
  if [[ ! -f "${STATE_FILE}" ]]; then
    log "state file missing at ${STATE_FILE}"
  else
    hostname_value="$(yq -r '.hostname // "unknown"' "${STATE_FILE}" 2>/dev/null || echo "unknown")"
    container_count="$(yq -r '.containers // [] | length' "${STATE_FILE}" 2>/dev/null || echo "0")"
    log "hostname=${hostname_value} containers=${container_count}"
  fi

  log "fetching remote config from ${remote_config_url}"
  rm -f "${CONFIG_NEW_FILE}" "${CONFIG_DOWNLOAD_FILE}"
  http_code="$(
    curl -sS --max-time 10 --output "${CONFIG_DOWNLOAD_FILE}" --write-out "%{http_code}" \
      "${remote_config_url}" 2>/dev/null || true
  )"

  if [[ "${http_code}" == "200" ]]; then
    log "remote config fetch succeeded (HTTP 200)"
    config_size_bytes="$(wc -c < "${CONFIG_DOWNLOAD_FILE}" | tr -d '[:space:]')"
    if (( config_size_bytes >= MAX_CONFIG_BYTES )); then
      log "config rejected (too large: ${config_size_bytes} bytes, max ${MAX_CONFIG_BYTES})"
      rm -f "${CONFIG_DOWNLOAD_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    if ! yq -e '.' "${CONFIG_DOWNLOAD_FILE}" >/dev/null 2>&1; then
      log "config rejected (invalid YAML)"
      rm -f "${CONFIG_DOWNLOAD_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    if ! yq -e '(.hostname | type) == "!!str" and (.hostname | length) > 0 and (.containers | type) == "!!seq"' \
      "${CONFIG_DOWNLOAD_FILE}" >/dev/null 2>&1; then
      log "config rejected (missing/invalid required fields: hostname:string, containers:array)"
      rm -f "${CONFIG_DOWNLOAD_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    mv -f "${CONFIG_DOWNLOAD_FILE}" "${CONFIG_NEW_FILE}"

    if [[ -f "${CONFIG_FILE}" ]] && cmp -s "${CONFIG_NEW_FILE}" "${CONFIG_FILE}"; then
      log "remote config unchanged"
      rm -f "${CONFIG_NEW_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    config_apply_tmp="$(mktemp "/var/lib/appcoreos/config.yaml.tmp.XXXXXX")"
    cat "${CONFIG_NEW_FILE}" > "${config_apply_tmp}"
    mv -f "${config_apply_tmp}" "${CONFIG_FILE}"
    log "config accepted and applied from remote"

    now_epoch="$(date +%s)"
    last_reboot_epoch=""
    if [[ -s "${LAST_REBOOT_TRIGGER_FILE}" ]]; then
      last_reboot_epoch="$(tr -d '[:space:]' < "${LAST_REBOOT_TRIGGER_FILE}")"
    fi

    if [[ "${last_reboot_epoch}" =~ ^[0-9]+$ ]] && (( now_epoch - last_reboot_epoch < MIN_REBOOT_INTERVAL_SECONDS )); then
      log "reboot suppressed (too frequent)"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    printf '%s\n' "${now_epoch}" > "${LAST_REBOOT_TRIGGER_FILE}"
    log "triggering reboot due to config change"
    exec systemctl reboot
  else
    log "remote config fetch skipped (HTTP ${http_code:-error})"
  fi

  sleep "${SLEEP_SECONDS}"
done
