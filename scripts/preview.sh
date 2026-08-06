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
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/$TRIPLE/debug/Lithe" "$APP_DIR/Contents/MacOS/Lithe"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R Resources/IDEAIcons "$APP_DIR/Contents/Resources/IDEAIcons"
for localization in en.lproj zh-Hans.lproj; do
    if [[ -d "Resources/$localization" ]]; then
        cp -R "Resources/$localization" "$APP_DIR/Contents/Resources/$localization"
    fi
done
codesign --force --deep --sign - "$APP_DIR"

exec "$APP_DIR/Contents/MacOS/Lithe"
