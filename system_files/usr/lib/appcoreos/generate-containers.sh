#!/usr/bin/env bash
set -euo pipefail

# Canonical machine config location from bootstrap.
CONFIG_PATH="/var/lib/appcoreos/config.yaml"
# Rootful Quadlet drop-in directory.
QUADLET_DIR="/etc/containers/systemd"

log() {
  echo "[generate-containers] $*"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required binary: $1"
    exit 1
  }
}

require_bin yq

if [[ ! -f "${CONFIG_PATH}" ]]; then
  log "Config not found: ${CONFIG_PATH}"
  exit 1
fi

mkdir -p "${QUADLET_DIR}"

# Full regeneration mode: remove all previous Quadlet container files first.
for old_file in "${QUADLET_DIR}"/*.container; do
  [[ -e "${old_file}" ]] || break
  old_name="$(basename "${old_file}" .container)"
  log "Removing old container definition: ${old_name}"
  rm -f "${old_file}"
done

container_count="$(yq -r '.containers // [] | length' "${CONFIG_PATH}")"
if [[ "${container_count}" -eq 0 ]]; then
  log "No containers defined in config."
  exit 0
fi

for ((i=0; i<container_count; i++)); do
  name="$(yq -r ".containers[${i}].name // \"\"" "${CONFIG_PATH}")"
  image="$(yq -r ".containers[${i}].image // \"\"" "${CONFIG_PATH}")"

  if [[ -z "${name}" || -z "${image}" ]]; then
    log "containers[${i}] requires both name and image."
    exit 1
  fi

  quadlet_file="${QUADLET_DIR}/${name}.container"

  {
    echo "# Generated from ${CONFIG_PATH}. Do not edit manually."
    echo "[Unit]"
    echo "Description=Container ${name}"
    echo
    echo "[Container]"
    echo "Image=${image}"
    echo "ContainerName=${name}"
    # Enable Podman registry-based auto-update for this container.
    echo "Label=io.containers.autoupdate=registry"
    # Keep container service behavior simple and consistent.
    echo "Restart=always"

    # Optional port list, e.g. "8080:80".
    while IFS= read -r port; do
      [[ -n "${port}" ]] || continue
      echo "PublishPort=${port}"
    done < <(yq -r ".containers[${i}].ports // [] | .[]" "${CONFIG_PATH}")
    echo
    echo "[Install]"
    echo "WantedBy=appcore.target"
  } > "${quadlet_file}"

  log "Creating container definition: ${name}"
done

log "Quadlet generation complete."
