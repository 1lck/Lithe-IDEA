#!/bin/zsh
# Swift-linked half of verify-rust-core.sh: the C ABI probe, Core symbols in the
# linked app, and Git execution integration through that app. Pass --skip-build
# after ./scripts/test-macos.sh has built the tests, as the CI Swift job does.
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

SKIP_BUILD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true; shift ;;
        *) print -u2 -- "Usage: $0 [--skip-build]"; exit 2 ;;
    esac
done

mkdir -p .artifacts/test-stability

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx"; RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-macosx"; RUST_TARGET="x86_64-apple-darwin" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

RUST_LIBRARY="$(scripts/build-rust-core.sh --debug --target "$RUST_TARGET")"

# Reuse the Swift test build: its Lithe executable links the same Core archive
# through test-macos.sh, so the bridge needs no second Swift compilation.
if [[ "$SKIP_BUILD" != true ]]; then
    ./scripts/test-macos.sh list > /dev/null
fi
SWIFT_BIN_PATH="$(swift build --show-bin-path --configuration debug)"
BINARY="$SWIFT_BIN_PATH/Lithe"
if [[ ! -x "$BINARY" ]]; then
    print -u2 -- "Swift test build has no Lithe executable at $BINARY; run ./scripts/test-macos.sh list first"
    exit 1
fi

BRIDGE_BINARY="$(mktemp -t lithe-rust-bridge).out"
trap 'rm -f "$BRIDGE_BINARY"' EXIT
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc scripts/RustCoreBridgeVerification.swift \
    macos/Sources/LitheRustCore/bridge.c \
    -sdk "$MACOS_SDK" \
    -target "${TRIPLE}13.0" \
    -Xlinker -force_load \
    -Xlinker "$RUST_LIBRARY" \
    -o "$BRIDGE_BINARY"
"$BRIDGE_BINARY"

if ! nm -gU "$BINARY" | grep -F "_lithe_core_execute_json" > /dev/null; then
    print -u2 -- "Rust Core symbols are missing from the macOS binary"
    exit 1
fi
if ! nm -gU "$BINARY" | grep -F "_lithe_core_lsp_provider_catalog_json" > /dev/null; then
    print -u2 -- "Rust Core LSP provider catalog symbol is missing from the macOS binary"
    exit 1
fi

# Exercise the same linked app's early AskPass mode as well as the C ABI and
# isolated local Git/HTTP flows. This lane never contacts an external remote.
cargo build --manifest-path rust/Cargo.toml -p lithe-core
python3 scripts/test-git-execution.py --application "$BINARY"
node --input-type=module -e 'import { writeTestReportArtifacts } from "./.agents/skills/write-stable-tests/scripts/generate-test-report.mjs"; writeTestReportArtifacts(".artifacts/test-stability/git-execution-integration.json");'

# Exercise the macOS journal through a real non-Git-feature entry point, and
# the Maven dependency-tree file through the linked bridge. These integrations
# remain explicit even though the ordinary Swift lane also links Core.
LITHE_RUN_GIT_EXECUTION_INTEGRATION=1 \
    ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
    --suite-timeout-seconds 900 \
    --report .artifacts/test-stability/git-console-bridge.json \
    -- --skip-build --filter 'MacGitHubGitOperationsTests|GitConsolePresentationBridgeTests|GitConsoleLifecycleBridgeTests|MavenDependencyTreeBridgeTests'

print "Rust Core Swift bridge verification passed: C ABI, linked symbols, and Git execution integration"
