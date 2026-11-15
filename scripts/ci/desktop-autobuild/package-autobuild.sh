#!/usr/bin/env bash
# Packages one architecture of the host OS for the Desktop AutoBuild:
#
#   package-autobuild.sh <arm64|amd64>
#
# AutoBuild builds and publishes without running application tests. It checks the macOS bundle
# signature before publication; fuller checks belong to Desktop Release. The version is
# the one in desktop/viva.toml. Signing follows the release: a complete certificate configuration
# signs, none uses an ad hoc macOS signature (unsigned on Windows), and a partial one is refused, so a broken secret fails
# the build instead of quietly publishing unsigned packages. The packages and a .sha256 file for
# each, whose entry contains only the file name, are copied flat into dist/autobuild/, the
# directory the workflow uploads; their names are printed last.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

if [[ $# -ne 1 ]]; then
    printf '%s\n' "Usage: $0 <arm64|amd64>" >&2
    exit 2
fi
ARCH="$1"
case "$ARCH" in
    arm64|amd64) ;;
    *) printf '%s\n' "The architecture must be arm64 or amd64, not $ARCH." >&2; exit 2 ;;
esac

VERSION="$(sed -n 's/^version = "\([0-9.]*\)"$/\1/p' "$ROOT_DIR/desktop/viva.toml")"
if [[ -z "$VERSION" ]]; then
    printf '%s\n' 'desktop/viva.toml has no [app] version.' >&2
    exit 1
fi
GOOS="$(go env GOOS)"

PACKAGE_CONTRACT="$ROOT_DIR/scripts/ci/common/desktop-packages.mjs"
FORMATS="$(node "$PACKAGE_CONTRACT" formats "$GOOS" "$ARCH")"
PACKAGE_NAMES="$(node "$PACKAGE_CONTRACT" names "$VERSION" "$GOOS" "$ARCH")"
PACKAGES=()
while IFS= read -r package; do PACKAGES+=("$package"); done <<< "$PACKAGE_NAMES"

SIGN_ARGS=()
case "$GOOS" in
    darwin)
        if [[ -n "${APPLE_CERTIFICATE:-}" ]]; then
            if [[ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]]; then
                printf '%s\n' 'APPLE_CERTIFICATE is set without APPLE_CERTIFICATE_PASSWORD.' >&2
                exit 1
            fi
        elif [[ -n "${APPLE_CERTIFICATE_PASSWORD:-}" || -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
            printf '%s\n' 'Incomplete Apple signing configuration: provide APPLE_CERTIFICATE, or remove the password and identity.' >&2
            exit 1
        else
            printf '%s\n' 'No Apple certificate is configured; sealing the app with an ad hoc signature (not Apple notarized).'
            SIGN_ARGS=(--ad-hoc-sign)
        fi
        ;;
    windows)
        if [[ -n "${WINDOWS_CERTIFICATE:-}" && -n "${WINDOWS_CERTIFICATE_PASSWORD:-}" ]]; then
            :
        elif [[ -n "${WINDOWS_CERTIFICATE:-}" || -n "${WINDOWS_CERTIFICATE_PASSWORD:-}" ]]; then
            printf '%s\n' 'Incomplete Windows signing configuration: provide both WINDOWS_CERTIFICATE and WINDOWS_CERTIFICATE_PASSWORD, or neither.' >&2
            exit 1
        else
            # A timestamp server alone signs nothing, so it does not count as a partial configuration.
            printf '%s\n' 'No Windows signing certificate is configured; the package is unsigned.'
            SIGN_ARGS=(--no-sign)
        fi
        ;;
    linux)
        ;;
    *) printf '%s\n' "Desktop packages are not supported on host OS $GOOS." >&2; exit 2 ;;
esac

PACKAGE_DIR="$ROOT_DIR/dist/desktop/$GOOS-$ARCH"
OUT_DIR="$ROOT_DIR/dist/autobuild"
"$ROOT_DIR/scripts/desktop/package-desktop.sh" --arch "$ARCH" --format "$FORMATS" --out "$PACKAGE_DIR" \
    "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}"

# Even without a Developer ID, the assembled bundle must have a valid resource seal.
# The linker's executable-only signature does not cover Info.plist or bundle resources.
if [[ "$GOOS" == darwin ]]; then
    codesign --verify --deep --strict "$PACKAGE_DIR/Lithe Desktop.app"
fi

mkdir -p "$OUT_DIR"
NAMES=()
for package in "${PACKAGES[@]}"; do
    if [[ ! -s "$PACKAGE_DIR/$package" ]]; then
        printf '%s\n' "viva package did not produce $PACKAGE_DIR/$package." >&2
        exit 1
    fi
    cp -f "$PACKAGE_DIR/$package" "$OUT_DIR/$package"
    (
        cd "$OUT_DIR"
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$package" > "$package.sha256"
        elif command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$package" > "$package.sha256"
        else
            printf '%s\n' 'Neither shasum nor sha256sum is available.' >&2
            exit 1
        fi
    )
    NAMES+=("$package" "$package.sha256")
done

printf '%s\n' "${NAMES[@]}"
