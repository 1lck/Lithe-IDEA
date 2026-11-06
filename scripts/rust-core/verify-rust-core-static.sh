#!/bin/zsh
# Platform-independent Rust checks; native crate execution stays on each host.
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
cargo fmt --manifest-path rust/Cargo.toml -p lithe-core -p lithe-core-rules -- --check
