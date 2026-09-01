#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
WARN_SECONDS=1
MAX_SECONDS=15
TERMINATE_SECONDS=45
SUITE_TIMEOUT_SECONDS=600
REPORT="$ROOT_DIR/.artifacts/test-stability/macos-swift.json"
SWIFT_ARGS=()

while (( $# > 0 )); do
    case "$1" in
        --warn-seconds)
            WARN_SECONDS="$2"
            shift 2
            ;;
        --max-seconds)
            MAX_SECONDS="$2"
            shift 2
            ;;
        --terminate-seconds)
            TERMINATE_SECONDS="$2"
            shift 2
            ;;
        --suite-timeout-seconds)
            SUITE_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --report)
            REPORT="$2"
            shift 2
            ;;
        --)
            shift
            SWIFT_ARGS=("$@")
            break
            ;;
        *)
            print -u2 -- "Unknown argument: $1"
            exit 2
            ;;
    esac
done

for command in node swift; do
    if ! command -v "$command" >/dev/null 2>&1; then
        print -u2 -- "macOS test stability requires $command; Bun is not required."
        exit 127
    fi
done

for argument in "${SWIFT_ARGS[@]}"; do
    if [[ "$argument" == "--parallel" ]]; then
        print -u2 -- "--parallel is not allowed: per-test watchdog attribution requires serial execution."
        exit 2
    fi
done

"$SCRIPT_DIR/verify-test-stability.sh"
node "$SCRIPT_DIR/run-swift-tests-with-timing.mjs" \
    --warn-ms "$(( WARN_SECONDS * 1000 ))" \
    --max-ms "$(( MAX_SECONDS * 1000 ))" \
    --terminate-ms "$(( TERMINATE_SECONDS * 1000 ))" \
    --suite-timeout-ms "$(( SUITE_TIMEOUT_SECONDS * 1000 ))" \
    --report "$REPORT" \
    -- "$ROOT_DIR/scripts/test-macos.sh" --no-parallel "${SWIFT_ARGS[@]}"
