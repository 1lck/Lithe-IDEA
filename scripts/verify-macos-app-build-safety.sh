#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

workbench_path="Sources/Lithe/Views/Workbench/WorkbenchView.swift"
drawing_group_pattern='\.drawingGroup\b'
workbench_rasterization_violations=$(
    rg -n "$drawing_group_pattern" "$workbench_path" || true
)

if ! print -r -- 'content.drawingGroup()' | rg -q "$drawing_group_pattern"; then
    print -u2 -- "The Workbench drawing-group safety pattern is not detecting the known failure form"
    exit 1
fi

if [[ -n "$workbench_rasterization_violations" ]]; then
    print -u2 -- "Workbench rendering safety violation:"
    print -u2 -- "WorkbenchView contains AppKit-backed controls and must not use drawingGroup()."
    print -u2 -- "SwiftUI otherwise fails with 'Unable to render flattened version' and displays yellow error tiles."
    print -u2 -- "$workbench_rasterization_violations"
    exit 1
fi

if ! rg -q 'verify-macos-app-build-safety\.sh' scripts/build-macos.sh; then
    print -u2 -- "macOS builds must run the rendering safety gate"
    exit 1
fi

for packaging_script in scripts/package-app.sh scripts/preview.sh; do
    if ! rg -q 'stamp-macos-app-build-info\.sh' "$packaging_script"; then
        print -u2 -- "$packaging_script must stamp traceable build metadata"
        exit 1
    fi
done

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/lithe-build-info-verification.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
test_plist="$temporary_directory/Info.plist"
cp Resources/Info.plist "$test_plist"

LITHE_BUILD_GIT_REVISION="0123456789abcdef0123456789abcdef01234567" \
LITHE_BUILD_GIT_BRANCH="test/rendering-safety" \
LITHE_BUILD_GIT_DIRTY="true" \
LITHE_BUILD_TIMESTAMP="2026-01-02T03:04:05Z" \
    scripts/stamp-macos-app-build-info.sh "$test_plist" >/dev/null 2>&1

assert_plist_value() {
    local key="$1"
    local expected="$2"
    local actual
    actual=$(/usr/bin/plutil -extract "$key" raw "$test_plist")
    if [[ "$actual" != "$expected" ]]; then
        print -u2 -- "Unexpected $key in stamped app metadata: $actual"
        exit 1
    fi
}

assert_plist_value LitheBuildGitRevision "0123456789abcdef0123456789abcdef01234567"
assert_plist_value LitheBuildGitBranch "test/rendering-safety"
assert_plist_value LitheBuildGitDirty "true"
assert_plist_value LitheBuildTimestamp "2026-01-02T03:04:05Z"

print -- "macOS app build safety verification passed"
