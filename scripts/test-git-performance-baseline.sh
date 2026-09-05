#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

# These are generated lane outputs. Remove only this lane's files so a failed
# or interrupted local run cannot be mistaken for a fresh successful sample.
rm -f \
    .artifacts/test-stability/macos-git-performance.json \
    .artifacts/test-stability/macos-git-performance-release.json \
    .artifacts/test-stability/macos-git-performance-release.log \
    .artifacts/performance/git-graph-baseline.json

DEBUG_TEST_ARGS=(--filter LitheGitPerformanceTests)
if [[ "${LITHE_GIT_PERFORMANCE_SKIP_TEST_BUILD:-0}" == "1" ]]; then
    DEBUG_TEST_ARGS=(--skip-build "${DEBUG_TEST_ARGS[@]}")
fi

# The Debug suite owns deterministic correctness and structural work gates. It
# deliberately avoids machine-time assertions so normal runner variance cannot
# turn an unchanged algorithm into a flaky failure.
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
    --report .artifacts/test-stability/macos-git-performance.json \
    --warn-seconds "${LITHE_GIT_PERFORMANCE_WARN_SECONDS:-1}" \
    --max-seconds "${LITHE_GIT_PERFORMANCE_MAX_SECONDS:-10}" \
    --stall-timeout-seconds 180 \
    --suite-timeout-seconds 600 \
    -- \
    "${DEBUG_TEST_ARGS[@]}"

SWIFT_BUILD_ARGS=(
    --disable-sandbox
    --configuration release
    -Xswiftc -Xfrontend
    -Xswiftc -disable-round-trip-debug-types
    -Xcc -include
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h"
)
if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_BUILD_ARGS+=(-Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh")
fi

# Build only the verifier product so Release mode does not compile unrelated
# app test targets whose testing hooks intentionally exist only in Debug. The
# Node runner supplies a local process-tree deadline before the CI timeout.
set +e
node scripts/run-git-performance-verifier.mjs \
    --timeout-seconds 300 \
    --benchmark .artifacts/performance/git-graph-baseline.json \
    --report .artifacts/test-stability/macos-git-performance-release.json \
    --log .artifacts/test-stability/macos-git-performance-release.log \
    -- \
    swift run "${SWIFT_BUILD_ARGS[@]}" LitheGitPerformanceVerifier \
        --output .artifacts/performance/git-graph-baseline.json
RELEASE_STATUS=$?
set -e

node .agents/skills/write-stable-tests/scripts/generate-test-report.mjs
exit "$RELEASE_STATUS"
