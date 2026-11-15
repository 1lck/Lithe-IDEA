#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
WARN_SECONDS=1
MAX_SECONDS=15
SUITE_TIMEOUT_SECONDS=600
REPORT="$ROOT_DIR/.artifacts/test-stability/macos-desktop-go.json"
FILTER='.'
PACKAGES=()

while (( $# > 0 )); do
    case "$1" in
        --warn-seconds) WARN_SECONDS="$2"; shift 2 ;;
        --max-seconds) MAX_SECONDS="$2"; shift 2 ;;
        --suite-timeout-seconds) SUITE_TIMEOUT_SECONDS="$2"; shift 2 ;;
        --report) REPORT="$2"; shift 2 ;;
        --package) PACKAGES+=("$2"); shift 2 ;;
        --) shift ;;
        --filter) FILTER="$2"; shift 2 ;;
        *) print -u2 -- "Unknown argument: $1"; exit 2 ;;
    esac
done

if (( ${#PACKAGES} == 0 )); then PACKAGES=(./...); fi
"$SCRIPT_DIR/verify-test-stability.sh"
node "$SCRIPT_DIR/run-go-tests-with-timing.mjs" \
    --warn-ms "$(( WARN_SECONDS * 1000 ))" \
    --max-ms "$(( MAX_SECONDS * 1000 ))" \
    --suite-timeout-ms "$(( SUITE_TIMEOUT_SECONDS * 1000 ))" \
    --report "$REPORT" \
    -- "$ROOT_DIR/scripts/desktop/desktop-go.sh" test -json -count=1 -p=1 -parallel=1 \
       -timeout="${SUITE_TIMEOUT_SECONDS}s" -run "$FILTER" "${PACKAGES[@]}"
