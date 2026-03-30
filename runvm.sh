#!/usr/bin/env bash
set -euo pipefail

IMAGE="build/appcoreos.qcow2"
NET_CIDR="192.168.122.0/24"
NET_HOST_IP="192.168.122.1"
NET_DHCP_START="192.168.122.10"
SNAPSHOT_MODE="${APPCOREOS_VM_SNAPSHOT:-1}"
SNAPSHOT_ARG=()
if [[ "${SNAPSHOT_MODE}" == "1" ]]; then
  SNAPSHOT_ARG=(-snapshot)
fi

if [[ ! -f "${IMAGE}" ]]; then
  echo "[runvm] ERROR: Image not found: ${IMAGE}"
  echo "[runvm] Run ./build.sh first"
  exit 1
fi

echo "[runvm] starting VM..."
echo "[runvm] image: ${IMAGE}"
echo "[runvm] mode: software emulation (tcg)"
echo "[runvm] guest networking: DHCP via QEMU user-net (${NET_CIDR})"
if [[ "${SNAPSHOT_MODE}" == "1" ]]; then
  echo "[runvm] disk mode: snapshot (ephemeral writes, base image untouched)"
else
  echo "[runvm] disk mode: persistent (writes stored in qcow2)"
fi
echo "[runvm] debug API (host): https://127.0.0.1:9090"
echo "[runvm] note: guest 192.168.122.x is NAT-internal and not directly reachable from host"
echo "[runvm] test: curl -k https://127.0.0.1:9090/health"
echo "[runvm] test: curl -k -H 'Authorization: Bearer <API_KEY>' https://127.0.0.1:9090/v1/state"
echo "[runvm] test: curl -k -H 'Authorization: Bearer <API_KEY>' https://127.0.0.1:9090/v1/containers"
echo "[runvm] test: curl -k -X POST -H 'Authorization: Bearer <API_KEY>' https://127.0.0.1:9090/v1/containers/<name>/restart"

exec qemu-system-x86_64 \
  -machine accel=tcg \
  -m 2048 \
  -cpu max \
  -drive file="${IMAGE}",format=qcow2,if=virtio \
  "${SNAPSHOT_ARG[@]}" \
  -nographic \
  -serial mon:stdio \
  -netdev user,id=net0,net="${NET_CIDR}",host="${NET_HOST_IP}",dhcpstart="${NET_DHCP_START}",hostfwd=tcp::9090-:9090 \
  -device e1000,netdev=net0
