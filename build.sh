#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="appcoreos:latest"
BUILDER_IMAGE_TAG="appcoreos-builder:latest"
BUILD_DIR="build"
LOG_DIR="build/logs"
LOG_FILE="${LOG_FILE:-}"
BASE_QCOW2_IMAGE="${BUILD_DIR}/fedora-cloud-base.qcow2"
QCOW2_IMAGE="${BUILD_DIR}/appcoreos.qcow2"
QCOW2_IMAGE_TMP="${BUILD_DIR}/appcoreos.tmp.qcow2"
MOUNT_DIR="${BUILD_DIR}/mnt"
NBD_DEVICE="${NBD_DEVICE:-}"
OS="$(uname -s)"
FEDORA_VERSION="43"
FEDORA_IMAGE_VERSION="1.6"
FEDORA_MIRROR="https://ftp.uni-stuttgart.de/fedora"
FEDORA_CLOUD_IMAGE_URL="${FEDORA_MIRROR}/releases/${FEDORA_VERSION}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${FEDORA_VERSION}-${FEDORA_IMAGE_VERSION}.x86_64.qcow2"

TARGET=""
CONTAINER_ID=""
MOUNT_METHOD=""
CHROOT_MOUNTS_ACTIVE=0
NBD_CONNECTED=0

log() {
  echo "$(date -Iseconds) [build] $*"
}

if [[ -f /.dockerenv ]] || grep -q container /proc/1/environ 2>/dev/null; then
  IN_CONTAINER=1
else
  IN_CONTAINER=0
fi

if [[ "${IN_CONTAINER}" == "0" ]]; then
  mkdir -p "${LOG_DIR}"
  if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
  fi
  exec > >(tee -a "${LOG_FILE}") 2>&1
fi

if [[ "${IN_CONTAINER}" == "1" ]] && [[ -n "${LOG_FILE}" ]]; then
  exec > >(tee -a "${LOG_FILE}") 2>&1
fi

log "build started"
if [[ -n "${LOG_FILE}" ]]; then
  log "log file: ${LOG_FILE}"
fi

usage() {
  cat <<'EOF'
Usage:
  ./build.sh --target local
  ./build.sh --target proxmox
  ./build.sh --target proxmox-internal
  ./build.sh --target mac
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
  if [[ "${CHROOT_MOUNTS_ACTIVE}" -eq 1 ]]; then
    root_cmd umount "${MOUNT_DIR}/run" >/dev/null 2>&1 || true
    root_cmd umount "${MOUNT_DIR}/sys" >/dev/null 2>&1 || true
    root_cmd umount "${MOUNT_DIR}/proc" >/dev/null 2>&1 || true
    root_cmd umount "${MOUNT_DIR}/dev" >/dev/null 2>&1 || true
  fi

  if [[ "${MOUNT_METHOD}" == "qemu-nbd" ]]; then
    if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
      root_cmd umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
    fi
    if [[ "${NBD_CONNECTED}" -eq 1 ]]; then
      root_cmd qemu-nbd --disconnect "${NBD_DEVICE}" >/dev/null 2>&1 || true
    fi
  else
    if [[ -d "${MOUNT_DIR}" ]] && mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
      root_cmd umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
    fi
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

build_proxmox_internal() {
  require_cmd qemu-img
  require_cmd qemu-nbd
  require_cmd curl
  require_cmd tar
  require_cmd chroot
  require_cmd mount
  require_cmd umount
  require_cmd mountpoint
  require_cmd lsblk
  require_cmd partprobe

  trap cleanup EXIT

  mkdir -p "${BUILD_DIR}" "${MOUNT_DIR}"
  rm -f "${BASE_QCOW2_IMAGE}" "${QCOW2_IMAGE}" "${QCOW2_IMAGE_TMP}"

  log "using Fedora version ${FEDORA_VERSION}"
  log "using image version ${FEDORA_IMAGE_VERSION}"
  log "using mirror ${FEDORA_MIRROR}"
  log "downloading from ${FEDORA_CLOUD_IMAGE_URL}"
  if ! curl -fL --retry 3 --retry-delay 2 "${FEDORA_CLOUD_IMAGE_URL}" -o "${BASE_QCOW2_IMAGE}"; then
    echo "Failed to download Fedora ${FEDORA_VERSION} cloud image" >&2
    exit 1
  fi

  log "preparing working qcow2 image: ${QCOW2_IMAGE}"
  cp "${BASE_QCOW2_IMAGE}" "${QCOW2_IMAGE}"

  log "mounting qcow2 image"
  log "using qemu-nbd to mount qcow2"
  log "initializing nbd devices"
  root_cmd modprobe nbd max_part=8 >/dev/null 2>&1 || true

  NBD_DEVICE=""
  for i in {0..7}; do
    if [[ -e "/dev/nbd${i}" ]]; then
      NBD_DEVICE="/dev/nbd${i}"
      break
    fi
  done

  if [[ -z "${NBD_DEVICE}" ]]; then
    echo "No /dev/nbd device found after modprobe" >&2
    exit 1
  fi

  log "using NBD device ${NBD_DEVICE}"
  ls -l /dev/nbd* || true

  root_cmd qemu-nbd --disconnect "${NBD_DEVICE}" >/dev/null 2>&1 || true
  root_cmd qemu-nbd --connect "${NBD_DEVICE}" "${QCOW2_IMAGE}"
  NBD_CONNECTED=1

  root_cmd partprobe "${NBD_DEVICE}" >/dev/null 2>&1 || true
  sleep 1

  nbd_partition="$(root_cmd lsblk -lnpo NAME,FSTYPE "${NBD_DEVICE}" | awk '$2 ~ /ext4|xfs|btrfs/ {print $1; exit}')"
  if [[ -z "${nbd_partition}" ]]; then
    echo "Failed to detect root partition on ${NBD_DEVICE}" >&2
    exit 1
  fi
  root_cmd mount "${nbd_partition}" "${MOUNT_DIR}"
  MOUNT_METHOD="qemu-nbd"
  log "mounted qcow2 via ${nbd_partition}"

  log "copying appliance rootfs overlay into mounted image"
  tar -C rootfs -cf - . | root_cmd tar -xpf - -C "${MOUNT_DIR}"

  log "binding pseudo-filesystems for chroot customization"
  root_cmd mkdir -p "${MOUNT_DIR}/dev" "${MOUNT_DIR}/proc" "${MOUNT_DIR}/sys" "${MOUNT_DIR}/run"
  root_cmd mount --bind /dev "${MOUNT_DIR}/dev"
  root_cmd mount -t proc proc "${MOUNT_DIR}/proc"
  root_cmd mount --bind /sys "${MOUNT_DIR}/sys"
  root_cmd mount --bind /run "${MOUNT_DIR}/run"
  CHROOT_MOUNTS_ACTIVE=1

  log "installing required runtime packages in image"
  root_cmd chroot "${MOUNT_DIR}" /usr/bin/dnf -y install podman systemd NetworkManager yq curl python3
  root_cmd chroot "${MOUNT_DIR}" /usr/bin/dnf -y remove openssh-server >/dev/null 2>&1 || true
  root_cmd chroot "${MOUNT_DIR}" /usr/bin/dnf clean all

  log "enabling required systemd units in image"
  root_cmd chroot "${MOUNT_DIR}" /usr/bin/systemctl mask getty@tty1.service
  root_cmd chroot "${MOUNT_DIR}" /usr/bin/systemctl enable \
    machine-config.service \
    containers.service \
    podman-auto-update.timer \
    state.timer \
    update-os.timer \
    machine-id.service \
    agent.service \
    tui.service \
    NetworkManager.service

  root_cmd sync

  log "unmounting qcow2 image"
  cleanup
  trap - EXIT
  MOUNT_METHOD=""
  CHROOT_MOUNTS_ACTIVE=0
  NBD_CONNECTED=0

  log "repacking qcow2 image"
  qemu-img convert -f qcow2 -O qcow2 "${QCOW2_IMAGE}" "${QCOW2_IMAGE_TMP}"
  mv -f "${QCOW2_IMAGE_TMP}" "${QCOW2_IMAGE}"

  log "proxmox artifact ready: ${QCOW2_IMAGE}"
}

build_builder_image() {
  log "building containerized builder image: ${BUILDER_IMAGE_TAG}"
  podman build -t "${BUILDER_IMAGE_TAG}" -f - . <<'EOF'
FROM quay.io/fedora/fedora:41

RUN dnf -y install \
      bash \
      coreutils \
      curl \
      dnf \
      e2fsprogs \
      kmod \
      parted \
      qemu-img \
      qemu-system-x86 \
      tar \
      util-linux \
    && dnf clean all \
    && rm -rf /var/cache/dnf
EOF
}

build_proxmox() {
  require_cmd podman
  build_image

  if [[ "${OS}" == "Darwin" ]]; then
    log "running build inside container (macOS compatibility mode)"
    build_builder_image
    log "starting non-interactive builder container"
    podman run --rm --privileged \
      --device /dev \
      -e LOG_FILE="${LOG_FILE}" \
      -v "$(pwd)":/workspace \
      -w /workspace \
      "${BUILDER_IMAGE_TAG}" \
      bash -c "./build.sh --target proxmox-internal"
    return
  fi

  build_proxmox_internal
}

build_mac() {
  require_cmd qemu-system-x86_64

  if [[ ! -f "${QCOW2_IMAGE}" ]]; then
    log "qcow2 image not found at ${QCOW2_IMAGE}; running proxmox build first"
    build_proxmox
  fi

  log "starting VM with qcow2 image: ${QCOW2_IMAGE}"
  cat <<EOF

VM controls:
  stop VM: Ctrl+A then X

Access:
  API on host:   http://127.0.0.1:8081
  debug on host: http://127.0.0.1:9090
EOF

  qemu-system-x86_64 \
    -machine accel=tcg \
    -cpu max \
    -m 2048 \
    -smp 2 \
    -drive file="${QCOW2_IMAGE}",format=qcow2,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::8081-:8081,hostfwd=tcp::9090-:9090 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
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
  proxmox-internal)
    build_proxmox_internal
    ;;
  mac)
    build_mac
    ;;
  *)
    echo "Invalid target: ${TARGET}" >&2
    usage
    exit 1
    ;;
esac
