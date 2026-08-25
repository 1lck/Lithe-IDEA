#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SWIFTPM_ENABLED=false
SWIFTPM_OUTCOME=skipped
SWIFTPM_HIT=""
CARGO_ENABLED=false
CARGO_OUTCOME=skipped
JDTLS_ENABLED=false
JDTLS_OUTCOME=skipped
JDK_ENABLED=false
JDK_OUTCOME=skipped

while [[ $# -gt 0 ]]; do
    case "$1" in
        --swiftpm-enabled) SWIFTPM_ENABLED="$2"; shift 2 ;;
        --swiftpm-outcome) SWIFTPM_OUTCOME="$2"; shift 2 ;;
        --swiftpm-hit) SWIFTPM_HIT="$2"; shift 2 ;;
        --cargo-enabled) CARGO_ENABLED="$2"; shift 2 ;;
        --cargo-outcome) CARGO_OUTCOME="$2"; shift 2 ;;
        --jdtls-enabled) JDTLS_ENABLED="$2"; shift 2 ;;
        --jdtls-outcome) JDTLS_OUTCOME="$2"; shift 2 ;;
        --jdk-enabled) JDK_ENABLED="$2"; shift 2 ;;
        --jdk-outcome) JDK_OUTCOME="$2"; shift 2 ;;
        *) print -u2 -- "Unknown option: $1"; exit 2 ;;
    esac
done

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

clear_artifact_cache() {
    local candidate="${1:A}"
    local artifact_root="$ROOT_DIR/.artifacts"
    artifact_root="${artifact_root:A}"
    if [[ "$candidate" != "$artifact_root"/* ]]; then
        print -u2 -- "Refusing to clear a cache outside the repository artifact root: $candidate"
        return 1
    fi
    rm -rf -- "$candidate"
    mkdir -p -- "$candidate"
}

swiftpm_root="$ROOT_DIR/.artifacts/swiftpm-cache"
cargo_cache="$ROOT_DIR/.artifacts/cargo-home/registry/cache"
jdtls_cache="$ROOT_DIR/.artifacts/jdtls-downloads"
jdk_cache="$ROOT_DIR/.artifacts/jdk-downloads"

if [[ "$SWIFTPM_ENABLED" == "true" && "$SWIFTPM_OUTCOME" != "success" ]]; then
    warning "SwiftPM cache restore failed" "GitHub cache restore reported $SWIFTPM_OUTCOME. The isolated cache will be discarded and dependencies will be resolved normally."
    clear_artifact_cache "$swiftpm_root"
fi
if [[ "$CARGO_ENABLED" == "true" && "$CARGO_OUTCOME" != "success" ]]; then
    warning "Cargo cache restore failed" "GitHub cache restore reported $CARGO_OUTCOME. The isolated cache will be discarded and crates will be downloaded normally."
    clear_artifact_cache "$cargo_cache"
fi
if [[ "$JDTLS_ENABLED" == "true" && "$JDTLS_OUTCOME" != "success" ]]; then
    warning "JDTLS cache restore failed" "GitHub cache restore reported $JDTLS_OUTCOME. The isolated cache will be discarded and artifacts will be downloaded normally."
    clear_artifact_cache "$jdtls_cache"
fi
if [[ "$JDK_ENABLED" == "true" && "$JDK_OUTCOME" != "success" ]]; then
    warning "JDK cache restore failed" "GitHub cache restore reported $JDK_OUTCOME. The isolated cache will be discarded and artifacts will be downloaded normally."
    clear_artifact_cache "$jdk_cache"
fi

verifier_arguments=()
if [[ "$CARGO_ENABLED" == "true" ]]; then
    verifier_arguments+=(
        --cargo-cache "$cargo_cache"
        --cargo-lock "$ROOT_DIR/rust/Cargo.lock"
    )
else
    verifier_arguments+=(--skip-cargo)
fi
if [[ "$SWIFTPM_ENABLED" == "true" ]]; then
    verifier_arguments+=(
        --swiftpm-cache "$swiftpm_root"
        --swiftpm-resolved "$ROOT_DIR/Package.resolved"
        --swift-version 6.2
    )
fi
if [[ "$JDTLS_ENABLED" == "true" ]]; then
    verifier_arguments+=(
        --jdtls-cache "$jdtls_cache"
        --jdtls-manifest "$ROOT_DIR/third_party/jdtls/manifest.json"
    )
fi
if [[ "$JDK_ENABLED" == "true" ]]; then
    verifier_arguments+=(
        --jdk-cache "$jdk_cache"
        --jdk-manifest "$ROOT_DIR/third_party/jdk/manifest.json"
    )
fi

if ! node "$ROOT_DIR/scripts/verify-download-cache.mjs" "${verifier_arguments[@]}"; then
    warning "Dependency cache validation failed" "The cache validator failed unexpectedly. All enabled caches will be cleared before the normal dependency path continues."
    [[ "$SWIFTPM_ENABLED" == "true" ]] && clear_artifact_cache "$swiftpm_root"
    [[ "$CARGO_ENABLED" == "true" ]] && clear_artifact_cache "$cargo_cache"
    [[ "$JDTLS_ENABLED" == "true" ]] && clear_artifact_cache "$jdtls_cache"
    [[ "$JDK_ENABLED" == "true" ]] && clear_artifact_cache "$jdk_cache"
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
    swiftpm_restored=false
    if [[ "$SWIFTPM_ENABLED" == "true" && "$SWIFTPM_OUTCOME" == "success" && -n "$SWIFTPM_HIT" ]]; then
        swiftpm_restored=true
    fi
    print -- "LITHE_SWIFTPM_CACHE_RESTORED=$swiftpm_restored" >> "$GITHUB_ENV"
fi

exit 0
