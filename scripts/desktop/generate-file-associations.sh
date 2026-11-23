#!/usr/bin/env bash
# Generates (or --check verifies) package file types from the bundled editor catalog and Core.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# This generator executes on the build host even when packaging another
# architecture. The package itself still uses its selected target stage.
GOARCH="$(go env GOHOSTARCH)"
export GOARCH
export LITHE_CORE_TARGET=""
exec "$ROOT_DIR/scripts/desktop/desktop-go.sh" run ./cmd/file-associations-manifest "$@"
