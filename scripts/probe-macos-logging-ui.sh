#!/bin/zsh
# Render the actual logging page with product localizations, outside installed bundles.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
if [[ "${1:-}" == --skip-build && $# == 1 ]]; then
    :
elif (( $# == 0 )); then
    ./scripts/test-macos.sh list > /dev/null
else
    print -u2 'Usage: probe-macos-logging-ui.sh [--skip-build]'
    exit 2
fi
bin_directory="$(swift build --show-bin-path --configuration debug)"
test_bundle="$bin_directory/LithePackageTests.xctest/Contents/MacOS/LithePackageTests"
swift_executable="$(xcrun --find swift)"
runner="${swift_executable:A:h:h}/libexec/swift/pm/swiftpm-testing-helper"
[[ -f "$test_bundle" && -x "$runner" ]] || { print -u2 'Build the macOS tests with the selected Xcode toolchain first'; exit 1; }
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/lithe-localized-logging.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
contents="$fixture_root/Lithe Logging UI.app/Contents"
mkdir -p "$contents/MacOS" "$ROOT_DIR/.artifacts/test-stability"
cp "$runner" "$contents/MacOS/LoggingValidation"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LoggingValidation</string>
<key>CFBundleIdentifier</key><string>app.lithe.logging.validation</string>
<key>CFBundleName</key><string>Lithe Logging UI Validation</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict></plist>
PLIST
zsh scripts/package-macos-localizations.sh macos/Resources "$contents/Resources"
# SwiftPM's ordinary helper has no product string tables. Package only a temporary
# copy; native views, callbacks and test desktop isolation remain unchanged.
LITHE_TEST_WINDOW_MODE=isolated LITHE_LOGGING_SCREENSHOTS="$ROOT_DIR/.artifacts/test-stability" \
    node .agents/skills/write-stable-tests/scripts/run-swift-tests-with-timing.mjs \
    --report .artifacts/test-stability/logging-native-render.json -- \
    "$contents/MacOS/LoggingValidation" --test-bundle-path "$test_bundle" \
    --filter DiagnosticsWorkflowTests.nativePageRenders "$test_bundle" --testing-library swift-testing
