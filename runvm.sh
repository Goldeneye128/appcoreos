#!/usr/bin/env bash
set -euo pipefail

IMAGE="build/appcoreos.qcow2"

if [[ ! -f "${IMAGE}" ]]; then
  echo "[runvm] ERROR: Image not found: ${IMAGE}"
  echo "[runvm] Run ./build.sh first"
  exit 1
fi

echo "[runvm] starting VM..."
echo "[runvm] image: ${IMAGE}"
echo "[runvm] mode: software emulation (tcg)"
echo "[runvm] guest networking: DHCP via QEMU user-net"
echo "[runvm] debug API (host): http://127.0.0.1:9090"
echo "[runvm] note: guest 10.0.2.x is NAT-internal and not directly reachable from host"
echo "[runvm] test: curl http://127.0.0.1:9090/state"
echo "[runvm] test: curl http://127.0.0.1:9090/containers"
echo "[runvm] test: curl http://127.0.0.1:9090/containers/<name>/logs?tail=200"
echo "[runvm] test: curl -X POST http://127.0.0.1:9090/containers/<name>/restart"

exec qemu-system-x86_64 \
  -machine accel=tcg \
  -m 2048 \
  -cpu max \
  -drive file="${IMAGE}",format=qcow2 \
  -nographic \
  -serial mon:stdio \
  -netdev user,id=net0,hostfwd=tcp::9090-:9090 \
  -device e1000,netdev=net0
