#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -x "$ROOT_DIR/.tools/go/bin/go" ]]; then
  GO_BIN="$ROOT_DIR/.tools/go/bin/go"
else
  GO_BIN="go"
fi

echo "Using Go: $($GO_BIN version)"
echo "Building appcorectl..."
"$GO_BIN" build -o "$ROOT_DIR/bin/appcorectl" ./cmd/appcorectl

echo "Running appcorectl --help..."
"$ROOT_DIR/bin/appcorectl" --help > /dev/null

echo "Build and run check succeeded."
