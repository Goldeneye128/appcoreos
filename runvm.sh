#!/usr/bin/env bash
set -euo pipefail

IMAGE="build/appcoreos.qcow2"

if [[ ! -f "${IMAGE}" ]]; then
  echo "[runvm] ERROR: Image not found: ${IMAGE}"
  echo "[runvm] Run ./build.sh first"
  exit 1
fi

echo "[runvm] starting VM..."

exec qemu-system-x86_64 \
  -m 2048 \
  -cpu host \
  -drive file="${IMAGE}",format=qcow2 \
  -nographic \
  -serial mon:stdio \
  -netdev user,id=net0 \
  -device e1000,netdev=net0
