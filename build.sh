#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="appcoreos:latest"
BUILD_DIR="build"
RAW_IMAGE="${BUILD_DIR}/appcoreos.raw"
QCOW2_IMAGE="${BUILD_DIR}/appcoreos.qcow2"
MOUNT_DIR="${BUILD_DIR}/mnt"

TARGET=""
CONTAINER_ID=""

log() {
  echo "$(date -Iseconds) [build] $*"
}

usage() {
  cat <<'EOF'
Usage:
  ./build.sh --target local
  ./build.sh --target proxmox
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

root_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "This step requires root privileges and sudo is not available." >&2
    exit 1
  fi
}

cleanup() {
  if [[ -d "${MOUNT_DIR}" ]] && mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
    root_cmd umount "${MOUNT_DIR}" || true
  fi
  if [[ -n "${CONTAINER_ID}" ]]; then
    podman rm "${CONTAINER_ID}" >/dev/null 2>&1 || true
  fi
}

build_image() {
  log "building image: ${IMAGE_TAG}"
  podman build -t "${IMAGE_TAG}" .
}

build_local() {
  require_cmd podman
  build_image
  log "local build complete"
  cat <<EOF

Run instructions:
  podman run --rm -it --privileged \\
    --cgroupns=host \\
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \\
    --name appcoreos-local \\
    ${IMAGE_TAG}
EOF
}

build_proxmox() {
  require_cmd podman
  require_cmd qemu-img
  require_cmd mkfs.ext4
  require_cmd mount
  require_cmd umount
  require_cmd mountpoint
  require_cmd tar

  trap cleanup EXIT

  mkdir -p "${BUILD_DIR}" "${MOUNT_DIR}"
  rm -f "${RAW_IMAGE}" "${QCOW2_IMAGE}"

  build_image

  log "creating raw disk image (2GB): ${RAW_IMAGE}"
  truncate -s 2G "${RAW_IMAGE}"

  log "formatting raw disk with ext4"
  root_cmd mkfs.ext4 -F "${RAW_IMAGE}" >/dev/null

  log "mounting raw disk image"
  root_cmd mount -o loop "${RAW_IMAGE}" "${MOUNT_DIR}"

  CONTAINER_ID="$(podman create "${IMAGE_TAG}")"
  log "extracting container filesystem into raw disk"
  podman export "${CONTAINER_ID}" | root_cmd tar -xpf - -C "${MOUNT_DIR}"
  root_cmd sync

  log "unmounting raw disk image"
  root_cmd umount "${MOUNT_DIR}"

  log "converting raw image to qcow2: ${QCOW2_IMAGE}"
  qemu-img convert -f raw -O qcow2 "${RAW_IMAGE}" "${QCOW2_IMAGE}"

  log "proxmox artifact ready: ${QCOW2_IMAGE}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${TARGET}" ]]; then
  usage
  exit 1
fi

case "${TARGET}" in
  local)
    build_local
    ;;
  proxmox)
    build_proxmox
    ;;
  *)
    echo "Invalid target: ${TARGET}" >&2
    usage
    exit 1
    ;;
esac
