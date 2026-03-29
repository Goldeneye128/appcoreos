#!/usr/bin/env bash
set -euo pipefail

# Canonical config destination on the writable runtime volume.
RUNTIME_DIR="/var/lib/your-os"
CONFIG_DEST="${RUNTIME_DIR}/config.yaml"

# Preferred external source (for first boot provisioning from mounted media).
ISO_CONFIG="/mnt/config/machine-config.yaml"

log() {
  # CHANGED: Include RFC3339 timestamp in all log lines.
  echo "$(date -Iseconds) [machine-config-bootstrap] $*"
}

mkdir -p "${RUNTIME_DIR}"
# CHANGED: Ensure mountpoint exists and try to mount ISO media safely.
mkdir -p /mnt/config
if mountpoint -q /mnt/config; then
  log "ISO mountpoint already mounted: /mnt/config"
elif [[ -b /dev/sr0 ]]; then
  timeout 2 mount -o ro /dev/sr0 /mnt/config >/dev/null 2>&1 || \
    log "ISO mount skipped (no media or mount timeout)."
else
  log "ISO device /dev/sr0 not present; skipping mount."
fi

if [[ -f "${ISO_CONFIG}" ]]; then
  log "Using ISO config source: ${ISO_CONFIG}"
  cp -f "${ISO_CONFIG}" "${CONFIG_DEST}"
elif [[ -f "${CONFIG_DEST}" ]]; then
  # Fallback is already in canonical destination.
  log "Using persisted config source: ${CONFIG_DEST}"
else
  # Keep first boot behavior deterministic: write a minimal DHCP default.
  log "No config source found; writing minimal DHCP default config."
  cat > "${CONFIG_DEST}" <<'EOF'
# Minimal fallback machine config.
network:
  dhcp: true
EOF
fi

# Apply hostname/network from the canonical config.
exec /usr/lib/your-os/apply-machine-config.sh "${CONFIG_DEST}"
