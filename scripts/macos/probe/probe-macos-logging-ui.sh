#!/bin/zsh
# Render the actual log window and diagnostic export dialog with product localizations, outside installed bundles.
set -euo pipefail
ROOT_DIR="${0:A:h:h:h:h}"
cd "$ROOT_DIR"
if [[ "${1:-}" == --skip-build && $# == 1 ]]; then
    :
elif (( $# == 0 )); then
    ./scripts/macos/test/test-macos.sh list > /dev/null
else
    print -u2 'Usage: probe-macos-logging-ui.sh [--skip-build]'
    exit 2
fi
bin_directory="$(swift build --show-bin-path --configuration debug)"
# The Swift Build system emits one bundle per test target; the legacy native build emits one package bundle.
test_bundle="$bin_directory/LitheTests.xctest/Contents/MacOS/LitheTests"
[[ -f "$test_bundle" ]] || test_bundle="$bin_directory/LithePackageTests.xctest/Contents/MacOS/LithePackageTests"
swift_executable="$(xcrun --find swift)"
runner="${swift_executable:A:h:h}/libexec/swift/pm/swiftpm-testing-helper"
[[ -f "$test_bundle" && -x "$runner" ]] || { print -u2 'Build the macOS tests with the selected Xcode toolchain first'; exit 1; }
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/lithe-localized-logging.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
contents="$fixture_root/Lithe Logging UI.app/Contents"
mkdir -p "$contents/MacOS" "$ROOT_DIR/.artifacts/test-stability"
cp "$runner" "$contents/MacOS/LoggingValidation"
codesign --force --sign - "$contents/MacOS/LoggingValidation"
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
zsh scripts/macos/package/package-macos-localizations.sh macos/Resources "$contents/Resources"
# The app registers its bundled UI fonts at launch; ship the same files so screenshots use product typography.
cp -R macos/Resources/Fonts "$contents/Resources/Fonts"
codesign --force --sign - "$fixture_root/Lithe Logging UI.app"
# SwiftPM's ordinary helper has no product string tables. Package only a temporary
# copy; native views, callbacks and test desktop isolation remain unchanged.
# Per-target test bundles link XCTest from the selected Xcode platform, not from the helper copy.
platform_developer="$(xcrun --show-sdk-platform-path)/Developer"
DYLD_FRAMEWORK_PATH="$platform_developer/Library/Frameworks" DYLD_LIBRARY_PATH="$platform_developer/usr/lib" \
LITHE_TEST_WINDOW_MODE=isolated LITHE_LOGGING_SCREENSHOTS="$ROOT_DIR/.artifacts/test-stability" \
    node .agents/skills/write-stable-tests/scripts/run-swift-tests-with-timing.mjs \
    --report .artifacts/test-stability/logging-native-render.json -- \
    "$contents/MacOS/LoggingValidation" --test-bundle-path "$test_bundle" \
    --filter 'DiagnosticsWorkflowTests.(nativePageRenders|logWindowMatchesMockup)' "$test_bundle" --testing-library swift-testing
