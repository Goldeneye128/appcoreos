#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="localhost/appcoreos:latest"
IMAGE_ARCH="amd64"
TARGET_ARCH="x86_64"
BIB_IMAGE="quay.io/centos-bootc/bootc-image-builder:latest"

BUILD_DIR="build"
LOG_DIR="${BUILD_DIR}/logs"
OUTPUT_DIR="${BUILD_DIR}/output"
TMP_DIR="${BUILD_DIR}/tmp"
QCOW2_IMAGE="${BUILD_DIR}/appcoreos.qcow2"

OS="$(uname -s)"
TARGET=""
CLEAN_BUILD=0
LOG_FILE=""

log() {
  echo "$(date -Iseconds) [build] $*"
}

usage() {
  cat <<'USAGE'
Usage:
  ./build.sh --target local
  ./build.sh --target proxmox
  ./build.sh --target mac

Optional flags:
  -d              delete build/ before starting
  -h, --help      show this help text
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

prepare_logging() {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  log "build started"
  log "log file: ${LOG_FILE}"
}

safe_clean_build_dir() {
  local build_realpath=""
  echo "[build] deleting build directory"
  if [[ -d "${BUILD_DIR}" ]]; then
    build_realpath="$(realpath "${BUILD_DIR}" 2>/dev/null || true)"
    if [[ -n "${build_realpath}" && "${build_realpath}" != "/" ]]; then
      rm -rf -- "${BUILD_DIR:?}/"
    fi
  fi
}

prepare_dirs() {
  mkdir -p "${OUTPUT_DIR}" "${TMP_DIR}" "${LOG_DIR}"
}

build_image_host() {
  log "using Fedora CoreOS base image"
  log "building image: ${IMAGE_REF} (${IMAGE_ARCH})"
  podman build --arch "${IMAGE_ARCH}" --pull=newer -t "${IMAGE_REF}" .
}

build_image_macos_machine() {
  local repo_path
  repo_path="$(pwd)"

  log "ensuring podman machine is running"
  podman machine start >/dev/null 2>&1 || true

  log "building image in podman machine (rootful)"
  podman machine ssh "cd '${repo_path}' && sudo podman build --arch '${IMAGE_ARCH}' --pull=newer -t '${IMAGE_REF}' ."
}

run_bib_local() {
  local repo_path
  repo_path="$(pwd)"

  prepare_dirs
  log "building qcow2 with bootc-image-builder"
  podman run --rm --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "${repo_path}/${OUTPUT_DIR}:/output" \
    -v "${repo_path}/${TMP_DIR}:/var/tmp" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB_IMAGE}" \
    --type qcow2 --target-arch "${TARGET_ARCH}" --rootfs=xfs "${IMAGE_REF}"
}

run_bib_macos_machine() {
  local repo_path
  repo_path="$(pwd)"

  prepare_dirs
  log "building qcow2 with bootc-image-builder in podman machine"
  podman machine ssh "cd '${repo_path}' && rm -rf '${OUTPUT_DIR}' '${TMP_DIR}' && mkdir -p '${OUTPUT_DIR}' '${TMP_DIR}' && sudo podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t -v '${repo_path}/${OUTPUT_DIR}:/output' -v '${repo_path}/${TMP_DIR}:/var/tmp' -v /var/lib/containers/storage:/var/lib/containers/storage '${BIB_IMAGE}' --type qcow2 --target-arch '${TARGET_ARCH}' --rootfs=xfs '${IMAGE_REF}'"
}

collect_qcow2_artifact() {
  local produced_qcow2
  produced_qcow2="${OUTPUT_DIR}/qcow2/disk.qcow2"

  if [[ ! -f "${produced_qcow2}" ]]; then
    echo "bootc-image-builder did not produce expected file: ${produced_qcow2}" >&2
    exit 1
  fi

  cp -f "${produced_qcow2}" "${QCOW2_IMAGE}"
  log "proxmox artifact ready: ${QCOW2_IMAGE}"
}

build_local() {
  require_cmd podman
  if [[ "${OS}" == "Darwin" ]]; then
    build_image_macos_machine
  else
    build_image_host
  fi
  log "local image build complete"
  cat <<EOF_RUN

Run instructions:
  podman run --rm -it --privileged \\
    --cgroupns=host \\
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \\
    --name appcoreos-local \\
    ${IMAGE_REF}
EOF_RUN
}

build_proxmox() {
  require_cmd podman

  if [[ "${OS}" == "Darwin" ]]; then
    build_image_macos_machine
    run_bib_macos_machine
  else
    build_image_host
    run_bib_local
  fi

  collect_qcow2_artifact
}

build_mac() {
  require_cmd qemu-system-x86_64
  local net_cidr net_host_ip net_dhcp_start
  net_cidr="192.168.122.0/24"
  net_host_ip="192.168.122.1"
  net_dhcp_start="192.168.122.10"

  if [[ ! -f "${QCOW2_IMAGE}" ]]; then
    log "qcow2 image missing; running proxmox build first"
    build_proxmox
  fi

  log "starting VM with qcow2 image: ${QCOW2_IMAGE}"
  cat <<EOF_RUN

VM controls:
  stop VM: Ctrl+A then X

Access:
  API on host:   http://127.0.0.1:8081
  debug on host: http://127.0.0.1:9090
  note: guest 192.168.122.x is NAT-internal in user-net mode
EOF_RUN

  qemu-system-x86_64 \
    -machine accel=tcg \
    -cpu max \
    -m 2048 \
    -smp 2 \
    -drive file="${QCOW2_IMAGE}",format=qcow2,if=virtio \
    -netdev user,id=net0,net="${net_cidr}",host="${net_host_ip}",dhcpstart="${net_dhcp_start}",hostfwd=tcp::9090-:9090 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    -d)
      CLEAN_BUILD=1
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

if [[ "${CLEAN_BUILD}" == "1" ]]; then
  safe_clean_build_dir
fi

prepare_logging
prepare_dirs

case "${TARGET}" in
  local)
    build_local
    ;;
  proxmox)
    build_proxmox
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
