#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx" ;;
    x86_64) TRIPLE="x86_64-apple-macosx" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

scripts/build-macos.sh --configuration debug --triple "$TRIPLE"
JDTLS_ROOT=$(scripts/prepare-jdtls.sh)
JDK_ROOT=$(LITHE_JDK_TARGET_ARCH="$(uname -m)" scripts/prepare-jdk.sh)

# 必须打成 .app 再启动：裸可执行文件没有 Info.plist，macOS 不会把它当成
# 前台应用，窗口能收到鼠标点击但永远拿不到键盘焦点。
PREVIEW_ROOT="$ROOT_DIR/.build/preview"
mkdir -p "$PREVIEW_ROOT"
# Every launch owns a separate bundle. AppKit decodes SVG resources lazily, so
# replacing a fixed bundle while an older preview is still running corrupts
# that process's cached images and can let missing-image placeholders cover the
# project tree and tool windows.
INSTANCE_DIR=$(mktemp -d "$PREVIEW_ROOT/instance.XXXXXX")
APP_DIR="$INSTANCE_DIR/Lithe.app"
WATCHER_OWNS_INSTANCE_CLEANUP=false
cleanup_instance_dir() {
    [[ -n "${INSTANCE_DIR:-}" && -d "$INSTANCE_DIR" ]] || return 0
    rm -rf -- "$INSTANCE_DIR"
}
trap '[[ "${WATCHER_OWNS_INSTANCE_CLEANUP:-false}" == true ]] || cleanup_instance_dir' EXIT HUP INT TERM

mkdir -p \
    "$APP_DIR/Contents/MacOS" \
    "$APP_DIR/Contents/Resources/LanguageServers" \
    "$APP_DIR/Contents/Resources/OfficialPlugins" \
    "$APP_DIR/Contents/Helpers"
cp ".build/$TRIPLE/debug/Lithe" "$APP_DIR/Contents/MacOS/Lithe"
swiftterm_resource_bundle=".build/$TRIPLE/debug/SwiftTerm_SwiftTerm.bundle"
if [[ ! -d "$swiftterm_resource_bundle" ]]; then
    print -u2 -- "Missing SwiftTerm Metal resource bundle: $swiftterm_resource_bundle"
    exit 1
fi
cp -R "$swiftterm_resource_bundle" "$APP_DIR/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp -R "$JDTLS_ROOT" "$APP_DIR/Contents/Resources/LanguageServers/jdtls"
cp -R "$JDK_ROOT" "$APP_DIR/Contents/Resources/LanguageServers/jdk"
plugin_root=$(scripts/build-official-plugins.sh --configuration debug --triple "$TRIPLE")
for plugin_package in "$plugin_root"/*(/N); do
    cp -R "$plugin_package" "$APP_DIR/Contents/Resources/OfficialPlugins/${plugin_package:t}"
done
case "$TRIPLE" in
    arm64-apple-macosx) RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64-apple-macosx) RUST_TARGET="x86_64-apple-darwin" ;;
esac
MACOSX_DEPLOYMENT_TARGET=13.0 \
    CARGO_TARGET_DIR="$ROOT_DIR/rust/target/macos" \
    cargo build --manifest-path "$ROOT_DIR/rust/Cargo.toml" -p lithe-db-sidecar --target "$RUST_TARGET"
cp "rust/target/macos/$RUST_TARGET/debug/lithe-db-sidecar" "$APP_DIR/Contents/Helpers/lithe-db-sidecar"
MACOSX_DEPLOYMENT_TARGET=13.0 \
    CARGO_TARGET_DIR="$ROOT_DIR/rust/target/macos" \
    cargo build --manifest-path "$ROOT_DIR/rust/Cargo.toml" -p lithe-db-mcp --target "$RUST_TARGET"
cp "rust/target/macos/$RUST_TARGET/debug/lithe-db-mcp" "$APP_DIR/Contents/Helpers/lithe-db-mcp"
cp macos/Resources/Info.plist "$APP_DIR/Contents/Info.plist"
"$ROOT_DIR/scripts/stamp-macos-app-build-info.sh" "$APP_DIR/Contents/Info.plist"
cp macos/Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R macos/Resources/IDEAIcons "$APP_DIR/Contents/Resources/IDEAIcons"
cp -R macos/Resources/DatabaseIcons "$APP_DIR/Contents/Resources/DatabaseIcons"
cp -R macos/Resources/Fonts "$APP_DIR/Contents/Resources/Fonts"
for localization in en.lproj zh-Hans.lproj; do
    if [[ -d "macos/Resources/$localization" ]]; then
        cp -R "macos/Resources/$localization" "$APP_DIR/Contents/Resources/$localization"
    fi
done
codesign --force --deep --sign - "$APP_DIR"

# Keep the launcher non-blocking while a watcher owns cleanup. The
# watcher waits for this specific app instance to exit, then removes its bundle.
(
    trap 'rm -rf -- "$INSTANCE_DIR"' EXIT HUP INT TERM
    set +e
    open -n -W "$APP_DIR" </dev/null >/dev/null 2>&1
    open_status=$?
    rm -rf -- "$INSTANCE_DIR"
    trap - EXIT HUP INT TERM
    exit "$open_status"
) &!
WATCHER_OWNS_INSTANCE_CLEANUP=true
trap - EXIT HUP INT TERM
print "Preview launched: $APP_DIR"
print "This command returns immediately; the instance directory is removed after the app exits."
