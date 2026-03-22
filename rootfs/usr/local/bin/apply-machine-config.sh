#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-/var/lib/your-os/config.yaml}"

log() {
  # CHANGED: Include RFC3339 timestamp in all log lines.
  echo "$(date -Iseconds) [apply-machine-config] $*"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required binary: $1"
    exit 1
  }
}

require_bin yq
require_bin hostnamectl
require_bin nmcli

if [[ ! -f "${CONFIG_PATH}" ]]; then
  log "Config not found: ${CONFIG_PATH}"
  exit 1
fi

# Apply hostname when present.
hostname_value="$(yq -r '.hostname // ""' "${CONFIG_PATH}")"
if [[ -n "${hostname_value}" ]]; then
  log "Applying hostname: ${hostname_value}"
  hostnamectl set-hostname "${hostname_value}"
fi

# Network defaults to DHCP when key is omitted.
network_mode="$(yq -r 'if (.network.dhcp // true) == true then "dhcp" else "static" end' "${CONFIG_PATH}")"
iface="$(yq -r '.network.interface // ""' "${CONFIG_PATH}")"

if [[ -z "${iface}" ]]; then
  # CHANGED: Pick Ethernet first when interface is not explicitly set.
  iface="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1; exit}')"
fi

if [[ -z "${iface}" ]]; then
  # CHANGED: Fallback to any non-loopback interface.
  iface="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2!="loopback"{print $1; exit}')"
fi

if [[ -z "${iface}" ]]; then
  # CHANGED: Missing interface is a warning; skip network and exit successfully.
  log "WARNING: No network interface found; skipping network configuration."
  log "Machine config applied successfully (network skipped)."
  exit 0
fi

connection="your-os-${iface}"

# Keep config idempotent by managing a dedicated connection profile.
if ! nmcli -t -f NAME connection show | grep -Fxq "${connection}"; then
  log "Creating NetworkManager profile: ${connection}"
  nmcli connection add type ethernet ifname "${iface}" con-name "${connection}" autoconnect yes
fi

nmcli connection modify "${connection}" connection.interface-name "${iface}" autoconnect yes

if [[ "${network_mode}" == "dhcp" ]]; then
  log "Applying DHCP on ${iface}"
  nmcli connection modify "${connection}" \
    ipv4.method auto \
    ipv4.addresses "" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.ignore-auto-dns no
else
  address="$(yq -r '.network.address // ""' "${CONFIG_PATH}")"
  gateway="$(yq -r '.network.gateway // ""' "${CONFIG_PATH}")"
  dns_list="$(yq -r '.network.dns // [] | join(" ")' "${CONFIG_PATH}")"

  if [[ -z "${address}" || -z "${gateway}" ]]; then
    log "Static mode requires network.address and network.gateway."
    exit 1
  fi

  log "Applying static IPv4 on ${iface}: ${address} via ${gateway}"
  nmcli connection modify "${connection}" \
    ipv4.method manual \
    ipv4.addresses "${address}" \
    ipv4.gateway "${gateway}" \
    ipv4.ignore-auto-dns yes

  if [[ -n "${dns_list}" ]]; then
    nmcli connection modify "${connection}" ipv4.dns "${dns_list}"
  else
    nmcli connection modify "${connection}" ipv4.dns ""
  fi
fi

# Bring the profile up immediately.
nmcli connection up "${connection}" >/dev/null
log "Machine config applied successfully."
