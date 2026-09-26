#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROFILE="release"
VERSION="${LITHE_VERSION:-0.1.0}"
ARCH="${LITHE_ARCH:-$(uname -m)}"
DIST_DIR="${LITHE_DIST_DIR:-$ROOT_DIR/dist}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            PROFILE="debug"
            shift
            ;;
        --release)
            PROFILE="release"
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

cd "$ROOT_DIR"

# 1. Build lithe-linux binary
"$SCRIPT_DIR/build-linux.sh" "--$PROFILE"

TARGET_BIN="${CARGO_TARGET_DIR:-$ROOT_DIR/target}/$PROFILE/lithe-linux"
PACKAGE_NAME="lithe-linux-${ARCH}-${VERSION}"
STAGE_DIR="$DIST_DIR/$PACKAGE_NAME"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin"
mkdir -p "$STAGE_DIR/share/applications"
mkdir -p "$STAGE_DIR/share/icons/hicolor/512x512/apps"

# 2. Copy binary
cp "$TARGET_BIN" "$STAGE_DIR/bin/lithe"
chmod +x "$STAGE_DIR/bin/lithe"

# 3. Create Desktop Entry
cat <<EOF > "$STAGE_DIR/share/applications/lithe.desktop"
[Desktop Entry]
Name=Lithe
Comment=Lithe IDE for Linux
Exec=lithe %F
Icon=lithe
Terminal=false
Type=Application
Categories=Development;IDE;
StartupWMClass=lithe
EOF

# 4. Copy icon if available
ICON_SRC="$ROOT_DIR/assets/icon.png"
if [[ ! -f "$ICON_SRC" ]]; then
    ICON_SRC=$(find "$ROOT_DIR/windows/tauri/src/extensions" -name "linux.svg" | head -n 1 || true)
fi

if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$STAGE_DIR/share/icons/hicolor/512x512/apps/lithe.png" || true
fi

# 5. Bundle the Java language-server runtime, aligned with the macOS and
# Windows installers (`LanguageServers/jdtls` + `LanguageServers/jdk`).
# Set LITHE_BUNDLE_RUNTIME=0 to skip (e.g. compile-only CI checks).
if [[ "${LITHE_BUNDLE_RUNTIME:-1}" != "0" ]]; then
    mkdir -p "$STAGE_DIR/share/LanguageServers"
    JDTLS_ROOT="$("$SCRIPT_DIR/prepare-jdtls-linux.sh")"
    cp -R "$JDTLS_ROOT" "$STAGE_DIR/share/LanguageServers/jdtls"
    JDK_ROOT="$("$SCRIPT_DIR/prepare-jdk-linux.sh")"
    cp -R "$JDK_ROOT" "$STAGE_DIR/share/LanguageServers/jdk"
fi

# 6. Create tar.gz archive
mkdir -p "$DIST_DIR"
TARBALL="$DIST_DIR/${PACKAGE_NAME}.tar.gz"
tar -czf "$TARBALL" -C "$DIST_DIR" "$PACKAGE_NAME"

printf '==> Linux package created: %s\n' "$TARBALL"
