#!/usr/bin/env bash
# Runs the checks every platform lane runs, so macOS, Linux and Windows verify the same code the
# same way: formatting, vet and tests, with dev-tagged build info and UI tests on every platform.
# A lane that skips one of these silently verifies less than its neighbours.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DESKTOP="$ROOT_DIR/desktop"
GO="$ROOT_DIR/scripts/desktop/desktop-go.sh"

# The UI packages are tested once, with the dev tag. Across everything they build, the tag swaps
# only two files. One is Viva's attribute checks, which can only add failures. The other sets
# buildinfo.Development, which the UI reads for the Dock badge, set only in a running window, and
# for the installed update channel, which a test build lacks either way: only packaging records
# one. A run without the tag would repeat the same tests (workbench alone takes about eight
# minutes on macOS and Windows) and check nothing more. buildinfo has tests for both values of
# the flag, so it runs both times.
DEV_TESTED=(./internal/settingswindow ./internal/pluginview ./internal/workbench)

unformatted="$(cd "$DESKTOP" && gofmt -l .)"
if [[ -n "$unformatted" ]]; then
    printf 'gofmt would change:\n%s\n' "$unformatted" >&2
    exit 1
fi

"$GO" vet ./...
"$GO" vet -tags dev ./...

all_packages="$("$GO" list ./...)"
dev_packages="$("$GO" list "${DEV_TESTED[@]}")"
untagged=()
while IFS= read -r package; do
    untagged+=("$package")
done < <(printf '%s\n' "$all_packages" | grep -vxF -f <(printf '%s\n' "$dev_packages"))
if (( ${#untagged[@]} != $(wc -l <<<"$all_packages") - ${#DEV_TESTED[@]} )); then
    printf 'Expected every package except %s in the untagged test run.\n' "${DEV_TESTED[*]}" >&2
    exit 1
fi

"$GO" test "${untagged[@]}"
if [[ "$(go env GOOS)" == windows ]]; then
    # A full Windows workbench run measured 588 seconds against Go's 10-minute package
    # deadline. Split its top-level tests into disjoint groups, each under the default deadline.
    "$GO" test -tags dev ./internal/buildinfo ./internal/settingswindow ./internal/pluginview
    "$GO" test -tags dev -run '^Test[A-C]' ./internal/workbench
    "$GO" test -tags dev -run '^Test[D-P]' ./internal/workbench
    "$GO" test -tags dev -skip '^Test[A-P]' ./internal/workbench
else
    "$GO" test -tags dev ./internal/buildinfo "${DEV_TESTED[@]}"
fi
