#!/bin/zsh
# Rust-only half of verify-rust-core.sh: comments, layout, formatting, host
# crates, and Core unit tests. It needs no Swift build, so CI runs it as its own
# light lane and leaves the linked Swift checks to the Swift tests job.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
cd "$ROOT_DIR"

mkdir -p .artifacts/test-stability
node --test --test-reporter=spec --test-reporter-destination=stdout \
    --test-reporter=junit --test-reporter-destination=.artifacts/test-stability/npm-progress.xml \
    rust/lithe-agent-host/tests/npm-progress.test.mjs
node --test --test-reporter=spec --test-reporter-destination=stdout \
    --test-reporter=junit --test-reporter-destination=.artifacts/test-stability/rust-comment-checker.xml \
    scripts/rust-core/test-rust-core-comments.mjs
scripts/rust-core/verify-rust-core-comments.sh
scripts/rust-core/verify-rust-core-layout.sh
cargo fmt --manifest-path rust/Cargo.toml -p lithe-core -- --check
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
cargo test --manifest-path rust/Cargo.toml -p lithe-core
