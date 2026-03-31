#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="${ROOT_DIR}/bin/appcorectl"
REQUIRED_GO_MINOR=26
TARGET_GOOS=""
TARGET_GOARCH=""

log() {
  printf '[build] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[build] ERROR: required command not found: $1" >&2
    exit 1
  fi
}

detect_target_platform() {
  case "$(uname -s)" in
    Darwin) TARGET_GOOS="darwin" ;;
    Linux) TARGET_GOOS="linux" ;;
    *)
      echo "[build] ERROR: unsupported host OS: $(uname -s)" >&2
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) TARGET_GOARCH="amd64" ;;
    arm64|aarch64) TARGET_GOARCH="arm64" ;;
    *)
      echo "[build] ERROR: unsupported host architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

local_go_version() {
  local version=""
  if command -v go >/dev/null 2>&1; then
    version="$(go env GOVERSION 2>/dev/null || true)"
    if [[ -z "${version}" ]]; then
      version="$(go version 2>/dev/null | awk '{print $3}' || true)"
    fi
  fi
  echo "${version}"
}

local_go_is_new_enough() {
  local goversion="$1"
  local trimmed major minor

  if [[ -z "${goversion}" ]]; then
    return 1
  fi

  trimmed="${goversion#go}"
  major="${trimmed%%.*}"
  trimmed="${trimmed#*.}"
  minor="${trimmed%%.*}"

  if [[ -z "${major}" || -z "${minor}" ]]; then
    return 1
  fi

  if (( major > 1 )); then
    return 0
  fi

  if (( major == 1 && minor >= REQUIRED_GO_MINOR )); then
    return 0
  fi

  return 1
}

build_with_local_go() {
  log "using local Go: $(go version)"
  (
    cd "${ROOT_DIR}"
    GOOS="${TARGET_GOOS}" GOARCH="${TARGET_GOARCH}" CGO_ENABLED=0 \
      go build -o "${BIN_PATH}" ./cmd/appcorectl
  )
}

build_with_container_go() {
  require_cmd podman
  log "local Go is too old; using containerized Go 1.26 build"
  podman run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e GOCACHE=/tmp/go-cache \
    -e GOOS="${TARGET_GOOS}" \
    -e GOARCH="${TARGET_GOARCH}" \
    -e CGO_ENABLED=0 \
    -v "${ROOT_DIR}:/workspace" \
    -w /workspace \
    docker.io/library/golang:1.26 \
    /usr/local/go/bin/go build -o /workspace/bin/appcorectl ./cmd/appcorectl
}

smoke_test() {
  log "running smoke test"
  "${BIN_PATH}" --help >/dev/null
}

main() {
  detect_target_platform
  mkdir -p "${ROOT_DIR}/bin"

  local goversion
  goversion="$(local_go_version)"
  if local_go_is_new_enough "${goversion}"; then
    build_with_local_go
  else
    build_with_container_go
  fi

  smoke_test
  log "build succeeded: ${BIN_PATH}"
}

main "$@"
