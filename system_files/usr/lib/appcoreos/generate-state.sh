#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/appcoreos"
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
require_bin python3

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
trap 'rm -f "${containers_raw}"' EXIT

if ! podman ps -a --format '{{.Names}}|{{.State}}' > "${containers_raw}" 2>/dev/null; then
  # Keep state generation resilient even if Podman returns an error.
  : > "${containers_raw}"
fi

HOSTNAME_VALUE="${hostname_value}" \
PRIMARY_IP="${primary_ip}" \
TIMESTAMP_VALUE="${timestamp}" \
CONTAINERS_FILE="${containers_raw}" \
python3 - <<'PY' > "${STATE_FILE}"
import json
import os

containers = []
containers_file = os.environ.get("CONTAINERS_FILE", "")
if containers_file and os.path.exists(containers_file):
    with open(containers_file, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            name, _, state = line.partition("|")
            state_norm = "running" if state.strip().lower() == "running" else "stopped"
            containers.append({"name": name.strip() or "unknown", "status": state_norm})

payload = {
    "hostname": os.environ.get("HOSTNAME_VALUE", ""),
    "primary_ip": os.environ.get("PRIMARY_IP", ""),
    "containers": containers,
    "timestamp": os.environ.get("TIMESTAMP_VALUE", ""),
}
print(json.dumps(payload, indent=2))
PY

log "State generated at ${STATE_FILE}"
