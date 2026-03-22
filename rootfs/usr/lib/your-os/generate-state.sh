#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/your-os"
STATE_FILE="${STATE_DIR}/state.json"

log() {
  echo "$(date -Iseconds) [generate-state] $*"
}

on_error() {
  log "ERROR: Failed to generate state.json"
}

trap on_error ERR

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: Missing required binary: $1"
    exit 1
  }
}

require_bin hostnamectl
require_bin ip
require_bin podman
require_bin yq

mkdir -p "${STATE_DIR}"

hostname_value="$(hostnamectl --static 2>/dev/null || hostname)"
timestamp="$(date -Iseconds)"

# Prefer route-derived source IP, then fallback to first global IPv4 address.
primary_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
if [[ -z "${primary_ip}" ]]; then
  primary_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')"
fi
primary_ip="${primary_ip:-}"

containers_raw="$(mktemp)"
containers_mapped="$(mktemp)"
trap 'rm -f "${containers_raw}" "${containers_mapped}"' EXIT

if ! podman ps -a --format json > "${containers_raw}" 2>/dev/null; then
  # Keep state generation resilient even if Podman returns an error.
  echo "[]" > "${containers_raw}"
fi

yq -o=json -I=0 '
  . // []
  | map({
      name: (
        if ((.Names | type) == "!!seq")
        then (.Names[0] // "unknown")
        else (.Names // .Name // "unknown")
        end
      ),
      status: (if ((.State // "") == "running") then "running" else "stopped" end)
    })
' "${containers_raw}" > "${containers_mapped}"

HOSTNAME_VALUE="${hostname_value}" \
PRIMARY_IP="${primary_ip}" \
TIMESTAMP_VALUE="${timestamp}" \
CONTAINERS_JSON="$(cat "${containers_mapped}")" \
yq -o=json -I=2 -n '
  {
    hostname: strenv(HOSTNAME_VALUE),
    primary_ip: strenv(PRIMARY_IP),
    containers: (strenv(CONTAINERS_JSON) | from_json),
    timestamp: strenv(TIMESTAMP_VALUE)
  }
' > "${STATE_FILE}"

log "State generated at ${STATE_FILE}"
