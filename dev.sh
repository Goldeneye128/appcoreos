#!/usr/bin/env bash
set -euo pipefail

echo "[dev] cleaning..."

echo "[dev] building..."
./build.sh --target proxmox -d

# Stop any existing AppCoreOS QEMU instance; ignore failures.
if command -v pkill >/dev/null 2>&1; then
  pkill -f 'qemu-system-x86_64.*appcoreos\.qcow2' >/dev/null 2>&1 || true
else
  killall qemu-system-x86_64 >/dev/null 2>&1 || true
fi

echo "[dev] starting VM..."
./runvm.sh
