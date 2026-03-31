#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build.sh"

if [[ ! -x "${BUILD_SCRIPT}" ]]; then
  chmod +x "${BUILD_SCRIPT}"
fi

"${BUILD_SCRIPT}"

echo "Build and run check succeeded."
