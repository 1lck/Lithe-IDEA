#!/bin/zsh
# Rust-only half of verify-rust-core.sh: comments, layout, formatting, host
# crates, and Core unit tests. It needs no Swift build, so CI runs it as its own
# light lane and leaves the linked Swift checks to the Swift tests job.
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

mkdir -p .artifacts/test-stability
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
node --test --test-reporter=spec --test-reporter-destination=stdout \
    --test-reporter=junit --test-reporter-destination=.artifacts/test-stability/plugin-sdk-node.xml \
    sdk/node/test/*.test.mjs
# The Java plugin SDK compiles for Java 8 with any newer JDK. When
# LITHE_PLUGIN_SDK_JAVA_RUNTIME names an older `java` (CI sets a Java 8 one),
# its tests and the sample backend run on that runtime instead of the build JDK.
for tool in java mvn; do
    command -v "$tool" >/dev/null || { print -u2 "verify-rust-core-crates: $tool is required for sdk/java."; exit 1; }
done
java_runtime="${LITHE_PLUGIN_SDK_JAVA_RUNTIME:-$(command -v java)}"
mvn -B -ntp -f sdk/java/pom.xml verify -Djvm="$java_runtime"
cp sdk/java/plugin-sdk/target/surefire-reports/TEST-*.xml .artifacts/test-stability/
# Opts the plugin SDK end-to-end tests in; they drive each sample backend
# through Core's real plugin session.
LITHE_PLUGIN_SDK_NODE="$(command -v node)" \
    LITHE_PLUGIN_SDK_JAVA="$java_runtime" \
    LITHE_PLUGIN_SDK_JAVA_SAMPLE="$ROOT_DIR/sdk/java/examples/sample-build/target/sample-build.jar" \
    cargo test --manifest-path rust/Cargo.toml -p lithe-core
