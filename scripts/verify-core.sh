#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

OUTPUT_DIR="$ROOT_DIR/.build/core-verification"
mkdir -p "$OUTPUT_DIR"

swiftc \
    Sources/Lithe/Models/GitModels.swift \
    Sources/Lithe/Models/SearchModels.swift \
    Sources/Lithe/Models/FileVisibilityRules.swift \
    Sources/Lithe/Models/GitGraphModels.swift \
    Sources/Lithe/Services/GitGraphLayoutService.swift \
    Sources/Lithe/Services/GitService.swift \
    scripts/CoreVerification.swift \
    -o "$OUTPUT_DIR/verify-core"

exec "$OUTPUT_DIR/verify-core"
