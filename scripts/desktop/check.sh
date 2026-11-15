#!/usr/bin/env bash
# Runs the checks every platform lane runs, so macOS, Linux and Windows verify the same code the
# same way: formatting, vet and tests, with the dev-tagged buildinfo package on every platform.
# A lane that skips one of these silently verifies less than its neighbours.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DESKTOP="$ROOT_DIR/desktop"
GO="$ROOT_DIR/scripts/desktop/desktop-go.sh"

unformatted="$(cd "$DESKTOP" && gofmt -l .)"
if [[ -n "$unformatted" ]]; then
    printf 'gofmt would change:\n%s\n' "$unformatted" >&2
    exit 1
fi

"$GO" vet ./...
"$GO" vet -tags dev ./...
"$GO" test ./...
"$GO" test -tags dev ./internal/buildinfo
