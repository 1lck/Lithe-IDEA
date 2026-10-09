#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

# CI separates Rust execution from linked Swift integrations so the latter can
# reuse the ordinary Swift test build in the same checkout and runner.
MODE="all"
if (( $# > 1 )); then
    print -u2 -- "Usage: $0 [--rust-only|--bridge-only]"
    exit 2
fi
if (( $# == 1 )); then
    case "$1" in
        --rust-only) MODE="rust" ;;
        --bridge-only) MODE="bridge" ;;
        *) print -u2 -- "Usage: $0 [--rust-only|--bridge-only]"; exit 2 ;;
    esac
fi

mkdir -p .artifacts/test-stability
if [[ "$MODE" != "bridge" ]]; then
    node --test --test-reporter=spec --test-reporter-destination=stdout \
        --test-reporter=junit --test-reporter-destination=.artifacts/test-stability/npm-progress.xml \
        rust/lithe-agent-host/tests/npm-progress.test.mjs
    node --test --test-reporter=spec --test-reporter-destination=stdout \
        --test-reporter=junit --test-reporter-destination=.artifacts/test-stability/rust-comment-checker.xml \
        scripts/test-rust-core-comments.mjs
    scripts/verify-rust-core-comments.sh
    scripts/verify-rust-core-layout.sh
    cargo fmt --manifest-path rust/Cargo.toml -p lithe-core -- --check
    node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
        --manifest rust/Cargo.toml --package lithe-git-host \
        --suite-timeout-ms 120000 \
        --report .artifacts/test-stability/git-host-rust.json
    node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
        --manifest rust/Cargo.toml --package lithe-agent-host \
        --suite-timeout-ms 120000 \
        --report .artifacts/test-stability/agent-host-rust.json
    node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
        --manifest rust/Cargo.toml --package lithe-ide-host \
        --report .artifacts/test-stability/ide-host-rust.json
    cargo build --locked --manifest-path rust/Cargo.toml -p lithe-ide-host --features mcp --bin lithe-mcp
    node --test scripts/test-ide-mcp.mjs
    cargo test --manifest-path rust/Cargo.toml -p lithe-core
    print "Rust Core verification passed: comments, layout, Rust tests, and MCP integration"
fi
if [[ "$MODE" == "rust" ]]; then exit 0; fi

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx"; RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-macosx"; RUST_TARGET="x86_64-apple-darwin" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

# Always let SwiftPM check the current source and linking inputs. Do not restore
# an app binary or blindly skip a build from a different job/toolchain. This is
# an incremental no-op after CI's canonical test-macos.sh list compilation.
scripts/test-macos.sh list > /dev/null
RUST_LIBRARY="$(scripts/build-rust-core.sh --debug --target "$RUST_TARGET")"
SWIFT_BIN_PATH="$(swift build --show-bin-path --configuration debug)"
BINARY="$SWIFT_BIN_PATH/Lithe"
if [[ ! -x "$BINARY" ]]; then
    print -u2 -- "The Swift test build did not produce the linked Lithe application: $BINARY"
    exit 1
fi

BRIDGE_DIRECTORY="$(mktemp -d -t lithe-rust-bridge)"
BRIDGE_BINARY="$BRIDGE_DIRECTORY/verify"
trap 'rm -rf -- "$BRIDGE_DIRECTORY"' EXIT
# Honor the SDK override used by SwiftPM as well as the default Xcode SDK.
MACOS_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
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

# The canonical build above already links the production archive, including all
# test targets. Keep runtime integrations explicit, without rebuilding the app
# under --triple or changing the linker arguments for this invocation.
LITHE_RUN_GIT_EXECUTION_INTEGRATION=1 \
    ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
    --suite-timeout-seconds 900 \
    --report .artifacts/test-stability/git-console-bridge.json \
    -- --skip-build --filter 'MacGitHubGitOperationsTests|GitConsolePresentationBridgeTests|GitConsoleLifecycleBridgeTests|MavenDependencyTreeBridgeTests'

print "Swift bridge verification passed: C ABI, linked symbols, and Git execution integration"
