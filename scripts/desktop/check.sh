#!/usr/bin/env bash
# Runs the checks every platform lane runs, so macOS, Linux and Windows verify the same code the
# same way: formatting, vet and tests, with dev-tagged build info and UI tests on every platform.
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
# A full Windows workbench run measured 588 seconds against Go's 10-minute
# package deadline. Split its top-level tests into disjoint groups, keeping the
# default deadline for every group and the same coverage for both build tags.
test_workbench_groups() {
    "$GO" test "$@" -run '^Test[A-C]' ./internal/workbench
    "$GO" test "$@" -run '^Test[D-P]' ./internal/workbench
    "$GO" test "$@" -skip '^Test[A-P]' ./internal/workbench
}

if [[ "$(go env GOOS)" == windows ]]; then
    listed_packages="$("$GO" list ./...)"
    packages=()
    while IFS= read -r package; do
        if [[ "$package" != */internal/workbench ]]; then
            packages+=("$package")
        fi
    done <<< "$listed_packages"
    "$GO" test "${packages[@]}"
    test_workbench_groups
    "$GO" test -tags dev ./internal/buildinfo ./internal/settingswindow ./internal/pluginview
    test_workbench_groups -tags dev
else
    "$GO" test ./...
    "$GO" test -tags dev ./internal/buildinfo ./internal/settingswindow ./internal/pluginview ./internal/workbench
fi
