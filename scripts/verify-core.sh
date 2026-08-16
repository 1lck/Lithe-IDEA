#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

swift run --quiet LitheCoreVerifier
"$ROOT_DIR/scripts/verify-service-boundaries.sh"
"$ROOT_DIR/scripts/verify-shared-contracts.sh"
