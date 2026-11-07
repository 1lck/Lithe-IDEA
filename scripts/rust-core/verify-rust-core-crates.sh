#!/bin/zsh
# Rust-only half of verify-rust-core.sh: comments, layout, formatting, host
# crates, and Core unit tests. It needs no Swift build, so CI runs it as its own
# light lane and leaves the linked Swift checks to the Swift tests job.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
cd "$ROOT_DIR"

# CI runs the static checks on Ubuntu in parallel with native tests. The local
# entrypoint retains the complete validation unless explicitly split by CI.
if [[ "${1:-}" == "--skip-static" && $# == 1 ]]; then
    :
elif [[ $# == 0 ]]; then
    ./scripts/rust-core/verify-rust-core-static.sh
else
    print -u2 -- "Usage: $0 [--skip-static]"
    exit 2
fi
mkdir -p .artifacts/test-stability
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
    --manifest rust/Cargo.toml --package lithe-git-host \
    --suite-timeout-ms 120000 \
    --report .artifacts/test-stability/git-host-rust.json
# Agent Host's ACP/MCP dependencies need the runner's default cold-build budget;
# its suite deadline includes compilation, while each test remains capped at 15s.
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
    --manifest rust/Cargo.toml --package lithe-agent-host \
    --report .artifacts/test-stability/agent-host-rust.json
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
    --manifest rust/Cargo.toml --package lithe-ide-host \
    --report .artifacts/test-stability/ide-host-rust.json
cargo build --locked --manifest-path rust/Cargo.toml -p lithe-ide-host --features mcp --bin lithe-mcp
node --test scripts/ide-mcp/test-ide-mcp.mjs
cargo test --manifest-path rust/Cargo.toml -p lithe-core-rules
cargo test --manifest-path rust/Cargo.toml -p lithe-core
