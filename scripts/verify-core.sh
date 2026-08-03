#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

OUTPUT_DIR="$ROOT_DIR/.build/core-verification"
mkdir -p "$OUTPUT_DIR"

swiftc \
    Sources/Lithe/Core/Ports/ProcessRunner.swift \
    Sources/Lithe/Core/Ports/RawProcessSession.swift \
    Sources/Lithe/Core/Ports/StreamingProcess.swift \
    Sources/Lithe/Core/Ports/WorkspaceFileOperations.swift \
    Sources/Lithe/Core/Terminal/TerminalBuffer.swift \
    Sources/Lithe/Platform/MacOS/Process/MacProcessRunner.swift \
    Sources/Lithe/Platform/MacOS/Process/MacRawProcessSession.swift \
    Sources/Lithe/Platform/MacOS/Process/MacStreamingProcess.swift \
    Sources/Lithe/Platform/MacOS/FileSystem/MacWorkspaceFileOperations.swift \
    Sources/Lithe/Models/GitModels.swift \
    Sources/Lithe/Models/SearchModels.swift \
    Sources/Lithe/Models/FileVisibilityRules.swift \
    Sources/Lithe/Models/GitGraphModels.swift \
    Sources/Lithe/Services/GitGraphLayoutService.swift \
    Sources/Lithe/Services/GitService.swift \
    scripts/CoreVerification.swift \
    -o "$OUTPUT_DIR/verify-core"

"$OUTPUT_DIR/verify-core"
"$ROOT_DIR/scripts/verify-service-boundaries.sh"
"$ROOT_DIR/scripts/verify-shared-contracts.sh"
