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
OS="$(uname -s)"
FEDORA_VERSION="43"
FEDORA_IMAGE_VERSION="1.6"
FEDORA_MIRROR="https://ftp.uni-stuttgart.de/fedora"
FEDORA_CLOUD_IMAGE_URL="${FEDORA_MIRROR}/releases/${FEDORA_VERSION}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${FEDORA_VERSION}-${FEDORA_IMAGE_VERSION}.x86_64.qcow2"

TARGET=""
IN_CONTAINER=0
REBUILD_BUILDER=0

log() {
  echo "$(date -Iseconds) [build] $*"
}

if [[ -f /.dockerenv ]]; then
  IN_CONTAINER=1
elif grep -qa 'container' /proc/1/environ 2>/dev/null; then
  IN_CONTAINER=1
fi

if [[ "${IN_CONTAINER}" == "0" ]]; then
  mkdir -p "${LOG_DIR}"
  if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
  fi
  exec > >(tee -a "${LOG_FILE}") 2>&1
fi

log "build started"
if [[ "${IN_CONTAINER}" == "1" ]]; then
  log "running inside builder container"
fi
if [[ "${IN_CONTAINER}" == "0" ]] && [[ -n "${LOG_FILE}" ]]; then
  log "log file: ${LOG_FILE}"
fi

usage() {
  cat <<'EOF'
Usage:
  ./build.sh --target local
  ./build.sh --target proxmox
  ./build.sh --target proxmox-internal
  ./build.sh --target mac
Optional flags:
  --rebuild-builder
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

build_image() {
  log "using Fedora 43 for appcoreos base image"
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
  ARCH="$(uname -m)"

  require_cmd qemu-img
  require_cmd curl
  require_cmd virt-copy-in
  require_cmd virt-customize
  require_cmd virt-filesystems

  export LIBGUESTFS_BACKEND=direct
  export LIBGUESTFS_DEBUG=1
  export LIBGUESTFS_TRACE=1
  if [[ "${ARCH}" == "aarch64" ]]; then
    export LIBGUESTFS_ARCH=x86_64
    log "forcing libguestfs architecture: x86_64"
  fi
  log "using libguestfs direct backend (no libvirt)"

  mkdir -p "${BUILD_DIR}"
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

  log "debugging image layout"
  virt-filesystems -a "${QCOW2_IMAGE}" --all --long || true

  log "copying appliance rootfs overlay into image"
  mapfile -t overlay_entries < <(find rootfs -mindepth 1 -maxdepth 1 -print)
  if [[ "${#overlay_entries[@]}" -gt 0 ]]; then
    virt-copy-in -a "${QCOW2_IMAGE}" "${overlay_entries[@]}" /
  fi

  log "customizing image packages and services"
  virt-customize \
    -a "${QCOW2_IMAGE}" \
    --install podman,yq,curl,python3,NetworkManager,systemd \
    --run-command "systemctl mask getty.target getty@.service serial-getty@.service rescue.service emergency.service console-getty.service serial-getty@ttyS0.service getty@ttyS0.service getty@tty1.service" \
    --run-command "if [ -e /sbin/agetty ]; then chmod 000 /sbin/agetty; fi" \
    --run-command "if command -v grubby >/dev/null 2>&1; then grubby --update-kernel=ALL --args='console=ttyS0'; else echo 'grubby command not found; cannot set console=ttyS0' >&2; exit 1; fi" \
    --run-command "sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME=\"App CoreOS 43\"/' /etc/os-release && sed -i 's/^NAME=.*/NAME=\"AppCoreOS\"/' /etc/os-release" \
    --run-command "systemctl enable machine-config.service containers.service podman-auto-update.timer state.timer update-os.timer machine-id.service agent.service tui.service NetworkManager.service"

  log "repacking qcow2 image"
  qemu-img convert -f qcow2 -O qcow2 "${QCOW2_IMAGE}" "${QCOW2_IMAGE_TMP}"
  mv -f "${QCOW2_IMAGE_TMP}" "${QCOW2_IMAGE}"

  log "proxmox artifact ready: ${QCOW2_IMAGE}"
}

build_builder_image() {
  log "using Fedora 43 for builder image"
  log "building builder image"
  podman build -t "${BUILDER_IMAGE_TAG}" -f - . <<'EOF'
FROM quay.io/fedora/fedora:43

RUN dnf -y install \
      bash \
      coreutils \
      curl \
      dnf \
      e2fsprogs \
      libguestfs-tools-c \
      qemu-img \
      tar \
      util-linux \
    && dnf clean all \
    && rm -rf /var/cache/dnf
EOF
  log "builder image ready"
}

ensure_builder_image() {
  if [[ "${REBUILD_BUILDER}" == "1" ]]; then
    build_builder_image
    return
  fi

  if podman image exists "${BUILDER_IMAGE_TAG}"; then
    log "reusing cached builder image"
    log "builder image ready"
    return
  fi

  build_builder_image
}

build_proxmox() {
  require_cmd podman
  build_image

  if [[ "${OS}" == "Darwin" ]]; then
    log "running build inside container (macOS compatibility mode)"
    ensure_builder_image
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
    --rebuild-builder)
      REBUILD_BUILDER=1
      shift
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
