#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
cd "$ROOT_DIR"

swift run --quiet LitheCoreVerifier
"$ROOT_DIR/scripts/architecture/verify-service-boundaries.sh"
"$ROOT_DIR/scripts/architecture/verify-shared-contracts.sh"
node "$ROOT_DIR/scripts/architecture/verify-java-semantic-ownership.mjs"
