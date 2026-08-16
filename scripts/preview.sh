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

# 必须打成 .app 再启动：裸可执行文件没有 Info.plist，macOS 不会把它当成
# 前台应用，窗口能收到鼠标点击但永远拿不到键盘焦点。
APP_DIR="$ROOT_DIR/.build/preview/Lithe.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp ".build/$TRIPLE/debug/Lithe" "$APP_DIR/Contents/MacOS/Lithe"
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
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R Resources/IDEAIcons "$APP_DIR/Contents/Resources/IDEAIcons"
cp -R Resources/DatabaseIcons "$APP_DIR/Contents/Resources/DatabaseIcons"
cp -R Resources/Fonts "$APP_DIR/Contents/Resources/Fonts"
for localization in en.lproj zh-Hans.lproj; do
    if [[ -d "Resources/$localization" ]]; then
        cp -R "Resources/$localization" "$APP_DIR/Contents/Resources/$localization"
    fi
done
codesign --force --deep --sign - "$APP_DIR"

exec open -n -W "$APP_DIR"
