#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
TARGET_TRIPLE="${APPCORECTL_TARGET:-x86_64-unknown-linux-gnu}"
CARGO_BUILD_SUBCOMMAND="${APPCORECTL_CARGO_BUILD_SUBCOMMAND:-build}"

log() {
  printf '[package] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[package] ERROR: required command not found: $1" >&2
    exit 1
  fi
}

checksum_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
    return
  fi
  echo ""
}

ensure_cargo_tool() {
  local binary="$1"
  local crate="$2"
  if command -v "${binary}" >/dev/null 2>&1; then
    return
  fi
  log "installing ${crate}"
  cargo install --locked "${crate}"
}

version() {
  python3 - <<'PY'
import tomllib
from pathlib import Path
data = tomllib.loads(Path("Cargo.toml").read_text(encoding="utf-8"))
print(data["package"]["version"])
PY
}

archive_basename() {
  local ver="$1"
  local arch="$2"
  printf 'appcorectl-%s-%s' "${ver}" "${arch}"
}

package_tarball() {
  local ver="$1"
  local arch="$2"
  local base
  base="$(archive_basename "${ver}" "${arch}")"
  local stage_dir="${DIST_DIR}/${base}"
  rm -rf "${stage_dir}"
  mkdir -p "${stage_dir}"
  install -m 0755 "${ROOT_DIR}/target/release/appcorectl" "${stage_dir}/appcorectl"
  install -m 0644 "${ROOT_DIR}/README.md" "${stage_dir}/README.md"
  install -m 0644 "${ROOT_DIR}/../LICENSE" "${stage_dir}/LICENSE"
  tar -C "${DIST_DIR}" -czf "${DIST_DIR}/${base}.tar.gz" "${base}"
  rm -rf "${stage_dir}"
  log "created ${DIST_DIR}/${base}.tar.gz"
}

main() {
  require_cmd cargo
  require_cmd python3

  mkdir -p "${DIST_DIR}"
  ensure_cargo_tool cargo-deb cargo-deb
  ensure_cargo_tool cargo-generate-rpm cargo-generate-rpm

  log "building release binary"
  (
    cd "${ROOT_DIR}"
    cargo "${CARGO_BUILD_SUBCOMMAND}" --release --locked --target "${TARGET_TRIPLE}"
  )

  if [[ "${TARGET_TRIPLE}" != "x86_64-unknown-linux-gnu" ]]; then
    echo "[package] ERROR: packaging currently expects TARGET_TRIPLE=x86_64-unknown-linux-gnu" >&2
    exit 1
  fi

  if command -v strip >/dev/null 2>&1; then
    if ! strip -s "${ROOT_DIR}/target/${TARGET_TRIPLE}/release/appcorectl"; then
      log "strip could not process ${TARGET_TRIPLE} binary on this host; continuing with unstripped binary"
    fi
  fi
  install -m 0755 "${ROOT_DIR}/target/${TARGET_TRIPLE}/release/appcorectl" "${ROOT_DIR}/target/release/appcorectl"

  local ver
  ver="$(cd "${ROOT_DIR}" && version)"
  package_tarball "${ver}" "linux-x86_64"

  log "building .deb package"
  (
    cd "${ROOT_DIR}"
    cargo deb --no-build --output "${DIST_DIR}/appcorectl_${ver}_amd64.deb"
  )

  log "building .rpm package"
  (
    cd "${ROOT_DIR}"
    cargo generate-rpm --output "${DIST_DIR}/appcorectl-${ver}-1.x86_64.rpm"
  )

  local sum_cmd
  sum_cmd="$(checksum_cmd)"
  if [[ -z "${sum_cmd}" ]]; then
    echo "[package] ERROR: missing sha256 checksum tool" >&2
    exit 1
  fi
  (
    cd "${DIST_DIR}"
    eval "${sum_cmd} ./* > SHA256SUMS"
  )
  log "packaging complete in ${DIST_DIR}"
}

main "$@"
