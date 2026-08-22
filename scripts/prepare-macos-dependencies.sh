#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CACHE_ROOT="${LITHE_SWIFTPM_CACHE_PATH:-$ROOT_DIR/.artifacts/swiftpm-cache}"
CACHE_ROOT="${CACHE_ROOT:A}"
ARTIFACT_ROOT="$ROOT_DIR/.artifacts"
ARTIFACT_ROOT="${ARTIFACT_ROOT:A}"

if [[ "$CACHE_ROOT" != "$ARTIFACT_ROOT"/* ]]; then
    print -u2 -- "SwiftPM cache must remain inside the repository artifact root: $CACHE_ROOT"
    exit 2
fi

warning() {
    local title="$1"
    local message="$2"
    print -u2 -- "warning: $title: $message"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        message="${message//'%'/'%25'}"
        message="${message//$'\r'/'%0D'}"
        message="${message//$'\n'/'%0A'}"
        print -- "::warning title=$title::$message"
    fi
}

clear_dependency_state() {
    rm -rf -- \
        "$CACHE_ROOT" \
        "$ROOT_DIR/.build/checkouts" \
        "$ROOT_DIR/.build/repositories" \
        "$ROOT_DIR/.build/workspace-state.json"
    mkdir -p -- "$CACHE_ROOT"
}

resolve_dependencies() {
    swift package \
        --cache-path "$CACHE_ROOT" \
        --only-use-versions-from-resolved-file \
        resolve
}

cd "$ROOT_DIR"
mkdir -p -- "$CACHE_ROOT"
if ! resolve_dependencies; then
    if [[ "${LITHE_SWIFTPM_CACHE_RESTORED:-false}" != "true" ]]; then
        exit 1
    fi
    warning "SwiftPM cache fallback" "Dependency resolution failed after a cache restore. Clearing repository-scoped dependency state and retrying once with an empty cache."
    clear_dependency_state
    resolve_dependencies
fi

if ! node "$ROOT_DIR/scripts/verify-download-cache.mjs" \
    --skip-cargo \
    --swiftpm-cache "$CACHE_ROOT" \
    --swiftpm-resolved "$ROOT_DIR/Package.resolved" \
    --swift-version 6.2 \
    --write-swiftpm-manifest; then
    warning "SwiftPM cache sealing failed" "Resolved checkouts remain available for this job, but the shared cache will be cleared instead of saving unverifiable content."
    rm -rf -- "$CACHE_ROOT"
    mkdir -p -- "$CACHE_ROOT"
fi
