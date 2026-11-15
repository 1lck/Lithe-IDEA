#!/usr/bin/env bash
# Packages the Viva desktop client for the host OS:
#
# Usage: scripts/desktop/package-desktop.sh [--arch arm64|amd64] [--format LIST] [--out DIR] [--no-sign] [--stable]
#
# --stable packages the stable release, which shows the plain version; without it the client shows
# the version as a preview. Only the Desktop Release passes it (scripts/ci/desktop-release).
#
# Viva builds the program from desktop/viva.toml, embeds that manifest and applies Windows
# resources and signing. It must receive desktop-go.sh's cgo environment so the packaged client
# links the staged core. The output defaults to dist/desktop/<os>-<arch>/; only the exact package
# names for this version, OS and architecture are replaced.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# desktop/go.mod (its require and replace) is the only place the Viva source is pinned; the tool is
# built from that same source, the Lithe-IDEA/viva fork through the replace, because
# "go install <module>@<version>" ignores replace directives. The download honours the replace and
# fills the module cache, and the Dir lookup names the directory of the source that gets built.
go -C "$ROOT_DIR/desktop" mod download github.com/vivaui/viva
VIVA_DIR="$(go -C "$ROOT_DIR/desktop" list -m -f '{{.Dir}}' github.com/vivaui/viva)"
# The version of the source actually built (the fork's pseudo-version, which names the commit) is the
# tool cache key; a replacement by a local directory has no version.
VIVA_VERSION="$(go -C "$ROOT_DIR/desktop" list -m -f '{{if .Replace}}{{.Replace.Version}}{{else}}{{.Version}}{{end}}' github.com/vivaui/viva)"
GOOS="$(go env GOOS)"
GOHOSTOS="$(go env GOHOSTOS)"
if [[ "$GOOS" != "$GOHOSTOS" ]]; then
    printf '%s\n' "Packaging requires the host GOOS: GOOS=$GOOS but the Go host is $GOHOSTOS." >&2
    exit 2
fi
ARCH="${GOARCH:-$(go env GOARCH)}"
FORMATS=""
OUT_DIR=""
SIGN_ARGS=()
STABLE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            if [[ $# -lt 2 ]]; then
                printf '%s\n' '--arch requires arm64 or amd64.' >&2
                exit 2
            fi
            ARCH="$2"
            shift 2
            ;;
        --format)
            if [[ $# -lt 2 ]]; then
                printf '%s\n' '--format requires a comma-separated format list.' >&2
                exit 2
            fi
            FORMATS="$2"
            shift 2
            ;;
        --out)
            if [[ $# -lt 2 ]]; then
                printf '%s\n' '--out requires a directory.' >&2
                exit 2
            fi
            OUT_DIR="$2"
            shift 2
            ;;
        --no-sign) SIGN_ARGS=(--no-sign); shift ;;
        --stable) STABLE=1; shift ;;
        *)
            printf '%s\n' "Usage: $0 [--arch arm64|amd64] [--format LIST] [--out DIR] [--no-sign] [--stable]" >&2
            exit 2
            ;;
    esac
done

case "$ARCH" in
    arm64|amd64) ;;
    *) printf '%s\n' "--arch must be arm64 or amd64, not $ARCH." >&2; exit 2 ;;
esac
if [[ "$GOOS" == "windows" && "$ARCH" != "amd64" ]]; then
    printf '%s\n' 'Windows packaging supports amd64 only.' >&2
    exit 2
fi

if [[ -z "$FORMATS" ]]; then
    case "$GOOS" in
        darwin) FORMATS="app,zip,dmg" ;;
        windows) FORMATS="nsis,zip" ;;
        linux) FORMATS="tar.gz,deb" ;;
        *) printf '%s\n' "Unsupported package host OS: $GOOS." >&2; exit 2 ;;
    esac
fi

MANIFEST="$ROOT_DIR/desktop/viva.toml"
VERSION="$(awk '
    /^\[app\][[:space:]]*$/ { in_app = 1; next }
    /^\[/ { in_app = 0 }
    in_app && /^version[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"[[:space:]]*$/ {
        sub(/^version[[:space:]]*=[[:space:]]*"/, "")
        sub(/"[[:space:]]*$/, "")
        print
        exit
    }
' "$MANIFEST")"
if [[ -z "$VERSION" ]]; then
    printf '%s\n' "$MANIFEST has no [app] version line of the form version = \"MAJOR.MINOR.PATCH\"." >&2
    exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$ROOT_DIR/dist/desktop/$GOOS-$ARCH"
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

# This versioned host-tool cache is writable build state owned by the worktree; it remains until the
# worktree or .artifacts/desktop/tools is removed. Viva uses it only while packaging; it is never
# copied into the app bundle or installed app, so it cannot affect code signing or Sparkle delta inputs.
if [[ -n "$VIVA_VERSION" ]]; then
    VIVA_BIN_DIR="$ROOT_DIR/.artifacts/desktop/tools/viva-$VIVA_VERSION"
else
    VIVA_BIN_DIR="$ROOT_DIR/.artifacts/desktop/tools/viva-local"
fi
mkdir -p "$VIVA_BIN_DIR"
VIVA_BIN_NAME="viva"
if [[ "$GOHOSTOS" == "windows" ]]; then
    VIVA_BIN_NAME="viva.exe"
fi
VIVA_BIN="$VIVA_BIN_DIR/$VIVA_BIN_NAME"
if [[ -z "$VIVA_VERSION" ]]; then
    # A local-directory replacement has no version to key the cache and its source can change: rebuild.
    rm -f -- "$VIVA_BIN"
fi
if [[ ! -f "$VIVA_BIN" ]]; then
    (
        unset GOOS GOARCH CGO_ENABLED CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_FFLAGS CGO_LDFLAGS \
            CGO_CFLAGS_ALLOW CGO_CFLAGS_DISALLOW CGO_LDFLAGS_ALLOW CGO_LDFLAGS_DISALLOW \
            CC GCCGO CXX FC PKG_CONFIG
        # -C makes -o relative to VIVA_DIR, so it must be absolute; VIVA_DIR already comes from go.
        go -C "$VIVA_DIR" build -o "$(native_path "$VIVA_BIN")" ./cmd/viva
    )
fi
if [[ ! -f "$VIVA_BIN" ]]; then
    printf '%s\n' "go build did not create the Viva tool at $VIVA_BIN." >&2
    exit 1
fi

case "$GOOS" in
    darwin)
        STEM="lithe-$VERSION-darwin-$ARCH"
        VIVA_OUT="$OUT_DIR/Lithe Desktop.app"
        rm -rf -- "$VIVA_OUT"
        rm -f -- "$OUT_DIR/$STEM.zip" "$OUT_DIR/$STEM.zip.sha256" \
            "$OUT_DIR/$STEM.dmg" "$OUT_DIR/$STEM.dmg.sha256"
        ;;
    windows)
        STEM="lithe-$VERSION-windows-$ARCH"
        VIVA_OUT="$OUT_DIR"
        rm -f -- "$OUT_DIR/$STEM-setup.exe" "$OUT_DIR/$STEM-setup.exe.sha256" \
            "$OUT_DIR/$STEM.zip" "$OUT_DIR/$STEM.zip.sha256"
        ;;
    linux)
        STEM="lithe-$VERSION-linux-$ARCH"
        VIVA_OUT="$OUT_DIR"
        rm -f -- "$OUT_DIR/$STEM.tar.gz" "$OUT_DIR/$STEM.tar.gz.sha256" \
            "$OUT_DIR/lithe_${VERSION}_${ARCH}.deb" "$OUT_DIR/lithe_${VERSION}_${ARCH}.deb.sha256"
        ;;
    *) printf '%s\n' "Unsupported package host OS: $GOOS." >&2; exit 2 ;;
esac

# The IDE API helper is embedded into the packaged Go binary under the lithe_bundled_helper
# build tag; the generated file is build input of this run only and never tracked. The client
# installs that copy under its application-data directory at first use, so the app bundle gets
# no extra executable and the client never reads its own installation for it. desktop-go.sh maps
# GOOS and ARCH to the core target, so the helper matches the package (the GNU target on Windows,
# x86_64 for an amd64 macOS package built on arm64) rather than the rustc host default.
HELPER_STAGE="$(GOARCH="$ARCH" LITHE_DESKTOP_CORE_PROFILE=release \
    "$ROOT_DIR/scripts/desktop/desktop-go.sh" --print-core-stage)"
HELPER_NAME="lithe-mcp"
if [[ "$GOOS" == "windows" ]]; then
    HELPER_NAME="lithe-mcp.exe"
fi
HELPER_SOURCE="$HELPER_STAGE/bin/$HELPER_NAME"
if [[ ! -f "$HELPER_SOURCE" ]]; then
    printf '%s\n' "The staged lithe-mcp helper is missing at $HELPER_SOURCE." >&2
    exit 1
fi
EMBED_FILE="$ROOT_DIR/desktop/internal/idehelp/lithe-mcp.bin"
mkdir -p "$(dirname "$EMBED_FILE")"
cp -- "$HELPER_SOURCE" "$EMBED_FILE"
trap 'rm -f -- "$EMBED_FILE"' EXIT

# The macOS client's fonts (desktop/internal/bundledfont/fonts, tracked in Git) are compiled into the
# executable under the lithe_bundled_fonts build tag, so the app bundle gets no font files and the
# client never reads its own installation for them. Other platforms ignore the tag.
BUILD_TAGS="lithe_bundled_helper,lithe_bundled_fonts"
# --stable, which only the Desktop Release passes for the commit of its desktop-v<version> tag, adds
# the lithe_stable build tag: the client then shows the plain version. Any other package, the daily
# AutoBuild or a local one, shows the version as a preview.
if [[ "$STABLE" == 1 ]]; then
    BUILD_TAGS="$BUILD_TAGS,lithe_stable"
    printf '%s\n' "Packaging the stable release $VERSION."
else
    printf '%s\n' "Packaging a preview of $VERSION."
fi
GOARCH="$ARCH" LITHE_DESKTOP_CORE_PROFILE=release \
    "$ROOT_DIR/scripts/desktop/desktop-go.sh" --exec "$VIVA_BIN" package \
    --target "$GOOS" --arch "$ARCH" --format "$FORMATS" -o "$VIVA_OUT" \
    -tags "$BUILD_TAGS" \
    "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}"
printf '%s\n' "$OUT_DIR"
