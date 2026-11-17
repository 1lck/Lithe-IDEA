#!/usr/bin/env bash
# Packages the Viva desktop client for the host OS:
#
# Usage: scripts/desktop/package-desktop.sh [--arch arm64|amd64] [--format LIST] [--out DIR] [--no-sign|--ad-hoc-sign] [--stable|--autobuild]
#
# --stable packages the stable release, which shows the plain version and updates from the stable
# channel; without it the client shows the version as a preview. Only the Desktop Release passes it
# (scripts/ci/desktop-release). --autobuild packages the daily AutoBuild, which updates from the
# AutoBuild channel (scripts/ci/desktop-autobuild). A package with neither, a local one, has no
# channel and never replaces itself.
#
# The channel, the build time (LITHE_BUILD_TIME, RFC 3339 UTC, else now), the commit
# (LITHE_BUILD_COMMIT, else git HEAD) and the feed keys (LITHE_UPDATE_PUBLIC_KEYS, public keys
# from 'viva update-keygen' separated by commas) go into a generated Go file. A build without keys
# cannot check a feed, so it does not update either.
#
# --ad-hoc-sign seals a macOS bundle without a Developer ID; it does not satisfy Gatekeeper.
# Viva builds the program from desktop/viva.toml, embeds that manifest and applies Windows
# resources and signing. It must receive desktop-go.sh's cgo environment so the packaged client
# links the staged core. The output defaults to dist/desktop/<os>-<arch>/; only the exact package
# names for this version, OS and architecture are replaced.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

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
CHANNEL=""
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
        --ad-hoc-sign) SIGN_ARGS=(--sign-identity -); shift ;;
        --stable) STABLE=1; shift ;;
        --autobuild) CHANNEL=autobuild; shift ;;
        *)
            printf '%s\n' "Usage: $0 [--arch arm64|amd64] [--format LIST] [--out DIR] [--no-sign|--ad-hoc-sign] [--stable|--autobuild]" >&2
            exit 2
            ;;
    esac
done

if [[ "$STABLE" == 1 ]]; then
    if [[ -n "$CHANNEL" ]]; then
        printf '%s\n' '--stable and --autobuild name different channels; pass one.' >&2
        exit 2
    fi
    CHANNEL=stable
fi

BUILD_TIME="${LITHE_BUILD_TIME:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
if [[ ! "$BUILD_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\n' "LITHE_BUILD_TIME must be an RFC 3339 UTC time such as 2026-11-16T10:00:00Z, not $BUILD_TIME." >&2
    exit 2
fi
BUILD_COMMIT="${LITHE_BUILD_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)}"
if [[ -n "$BUILD_COMMIT" && ! "$BUILD_COMMIT" =~ ^[0-9a-f]{7,64}$ ]]; then
    printf '%s\n' "LITHE_BUILD_COMMIT must be a hexadecimal Git commit, not $BUILD_COMMIT." >&2
    exit 2
fi
UPDATE_KEYS="$(printf '%s' "${LITHE_UPDATE_PUBLIC_KEYS:-}" | tr -d '[:space:]')"
if [[ ! "$UPDATE_KEYS" =~ ^[A-Za-z0-9+/=,]*$ ]]; then
    printf '%s\n' 'LITHE_UPDATE_PUBLIC_KEYS must be base64 or hexadecimal public keys separated by commas.' >&2
    exit 2
fi
if [[ -n "$CHANNEL" && -z "$UPDATE_KEYS" ]]; then
    printf '%s\n' "warning: LITHE_UPDATE_PUBLIC_KEYS is empty, so this $CHANNEL package cannot check its feed and will not update." >&2
fi

case "$ARCH" in
    arm64|amd64) ;;
    *) printf '%s\n' "--arch must be arm64 or amd64, not $ARCH." >&2; exit 2 ;;
esac
if [[ "$GOOS" == "windows" && "$ARCH" != "amd64" ]]; then
    printf '%s\n' 'Windows packaging supports amd64 only.' >&2
    exit 2
fi

if [[ -z "$FORMATS" ]]; then
    FORMATS="$(node "$ROOT_DIR/scripts/ci/common/desktop-packages.mjs" formats "$GOOS" "$ARCH")"
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

# The viva tool comes from the fork desktop/go.mod pins (scripts/desktop/build-viva-tool.sh).
VIVA_BIN="$("$ROOT_DIR/scripts/desktop/build-viva-tool.sh")"

PACKAGE_NAMES="$(node "$ROOT_DIR/scripts/ci/common/desktop-packages.mjs" names "$VERSION" "$GOOS" "$ARCH")"
while IFS= read -r package; do
    rm -f -- "$OUT_DIR/$package" "$OUT_DIR/$package.sha256"
done <<< "$PACKAGE_NAMES"
VIVA_OUT="$OUT_DIR"
if [[ "$GOOS" == darwin ]]; then
    VIVA_OUT="$OUT_DIR/Lithe Desktop.app"
    rm -rf -- "$VIVA_OUT"
fi

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
PACKAGE_INFO_FILE="$ROOT_DIR/desktop/internal/buildinfo/package_info.go"
trap 'rm -f -- "$EMBED_FILE" "$PACKAGE_INFO_FILE"' EXIT

# viva package links with fixed flags, so the build's channel, time, commit and feed keys reach
# internal/buildinfo as a generated file under the lithe_package_info build tag instead of -X. Like
# the helper it is build input of this run only, Git-ignored, and removed when packaging ends. Each
# value was checked above to hold no character a Go string would need escaped.
{
    printf '%s\n' '// Code generated by scripts/desktop/package-desktop.sh. DO NOT EDIT.' ''
    printf '%s\n' '//go:build lithe_package_info' '' 'package buildinfo' '' 'func init() {'
    printf '\tChannel = "%s"\n' "$CHANNEL"
    printf '\tBuildTime = "%s"\n' "$BUILD_TIME"
    printf '\tCommit = "%s"\n' "$BUILD_COMMIT"
    printf '\tUpdatePublicKeys = "%s"\n' "$UPDATE_KEYS"
    printf '%s\n' '}'
} > "$PACKAGE_INFO_FILE"

# The macOS client's fonts (desktop/internal/bundledfont/fonts, tracked in Git) are compiled into the
# executable under the lithe_bundled_fonts build tag, so the app bundle gets no font files and the
# client never reads its own installation for them. Other platforms ignore the tag.
BUILD_TAGS="lithe_bundled_helper,lithe_bundled_fonts,lithe_package_info"
# --stable, which only the Desktop Release passes for the commit of its desktop-v<version> tag, adds
# the lithe_stable build tag: the client then shows the plain version. Any other package, the daily
# AutoBuild or a local one, shows the version as a preview.
if [[ "$STABLE" == 1 ]]; then
    BUILD_TAGS="$BUILD_TAGS,lithe_stable"
    printf '%s\n' "Packaging the stable release $VERSION."
else
    printf '%s\n' "Packaging a preview of $VERSION${CHANNEL:+ for the $CHANNEL channel}."
fi
# Every target links Rust Core; Viva's pure-Go Linux/Windows default would omit its C ABI bridge.
GOARCH="$ARCH" LITHE_DESKTOP_CORE_PROFILE=release \
    "$ROOT_DIR/scripts/desktop/desktop-go.sh" --exec "$VIVA_BIN" package \
    --target "$GOOS" --arch "$ARCH" --format "$FORMATS" -o "$VIVA_OUT" \
    --cgo \
    -tags "$BUILD_TAGS" \
    "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}"
printf '%s\n' "$OUT_DIR"
