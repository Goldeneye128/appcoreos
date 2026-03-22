#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/lib/your-os/state.json"
LAST_UPDATE_FILE="/var/lib/your-os/last-update"
REFRESH_SECONDS=2

log() {
  echo "$(date -Iseconds) [tui] $*" >&2
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing required binary: $1"
    exit 1
  }
}

require_bin yq
require_bin date

while true; do
  # Reset screen and draw full frame.
  printf '\033[2J\033[H'
  echo "Your-OS v0.1"
  echo

  if [[ -f "${STATE_FILE}" ]]; then
    hostname_value="$(yq -r '.hostname // "unknown"' "${STATE_FILE}" 2>/dev/null || echo "unknown")"
    ip_value="$(yq -r '.primary_ip // "unknown"' "${STATE_FILE}" 2>/dev/null || echo "unknown")"
  else
    hostname_value="unknown"
    ip_value="unknown"
  fi

  echo "Hostname: ${hostname_value}"
  echo "IP: ${ip_value}"
  echo
  echo "Containers:"

  if [[ -f "${STATE_FILE}" ]]; then
    container_count="$(yq -r '.containers // [] | length' "${STATE_FILE}" 2>/dev/null || echo "0")"
    if [[ "${container_count}" -gt 0 ]]; then
      for ((i=0; i<container_count; i++)); do
        name="$(yq -r ".containers[${i}].name // \"unknown\"" "${STATE_FILE}" 2>/dev/null || echo "unknown")"
        status="$(yq -r ".containers[${i}].status // \"unknown\"" "${STATE_FILE}" 2>/dev/null || echo "unknown")"
        echo "- ${name} (${status})"
      done
    else
      echo "- none"
    fi
  else
    echo "- state unavailable"
  fi

  if [[ -e "${LAST_UPDATE_FILE}" ]]; then
    last_update="$(date -Iseconds -r "${LAST_UPDATE_FILE}" 2>/dev/null || echo "unknown")"
  else
    last_update="never"
  fi

  echo
  echo "Last update: ${last_update}"

  sleep "${REFRESH_SECONDS}"
done
