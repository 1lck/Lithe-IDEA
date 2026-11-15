#!/usr/bin/env bash
# Packages and verifies one architecture of the host OS for a Desktop Release:
#
#   package-release.sh <arm64|amd64> <version>
#
# macOS signing uses APPLE_CERTIFICATE and APPLE_CERTIFICATE_PASSWORD, with an optional identity.
# Windows signing uses WINDOWS_CERTIFICATE and WINDOWS_CERTIFICATE_PASSWORD, with an optional
# WINDOWS_TIMESTAMP_URL. A missing certificate pair makes an unsigned package; a partial pair is
# refused. Linux packages are unsigned. Every archive or installer gets a checked .sha256 file
# whose entry contains only the artifact's file name; the verified artifact paths are printed last.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

if [[ $# -ne 2 ]]; then
    printf '%s\n' "Usage: $0 <arm64|amd64> <version>" >&2
    exit 2
fi
ARCH="$1"
VERSION="$2"
case "$ARCH" in
    arm64|amd64) ;;
    *) printf '%s\n' "The architecture must be arm64 or amd64, not $ARCH." >&2; exit 2 ;;
esac

GOOS="$(go env GOOS)"
GOHOSTOS="$(go env GOHOSTOS)"
if [[ "$GOOS" != "$GOHOSTOS" ]]; then
    printf '%s\n' "Release packaging requires the host GOOS: GOOS=$GOOS but the Go host is $GOHOSTOS." >&2
    exit 2
fi
MANIFEST_VERSION="$(sed -n 's/^version = "\([0-9.]*\)"$/\1/p' "$ROOT_DIR/desktop/viva.toml")"
if [[ "$VERSION" != "$MANIFEST_VERSION" ]]; then
    printf '%s\n' "Requested version $VERSION does not match desktop/viva.toml version $MANIFEST_VERSION." >&2
    exit 1
fi
# The packages are the stable release (package-desktop.sh --stable), which shows the plain version:
# the release publishes them under desktop-v<version>, the tag of the commit built. A run started by
# pushing that tag must find it on HEAD; a manual run creates the tag on this commit when it
# publishes, or publishes nothing.
RELEASE_TAG="desktop-v$VERSION"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]] && ! git -C "$ROOT_DIR" tag --points-at HEAD | grep -Fqx -- "$RELEASE_TAG"; then
    printf '%s\n' "The checked-out commit does not carry $RELEASE_TAG, the tag this release publishes." >&2
    exit 1
fi

SIGN_ARGS=()
SIGNED=0
case "$GOOS" in
    darwin)
        case "$ARCH" in
            arm64) MACHINE_ARCH="arm64" ;;
            amd64) MACHINE_ARCH="x86_64" ;;
        esac
        if [[ -n "${APPLE_CERTIFICATE:-}" ]]; then
            if [[ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]]; then
                printf '%s\n' 'APPLE_CERTIFICATE is set without APPLE_CERTIFICATE_PASSWORD.' >&2
                exit 1
            fi
            SIGNED=1
        elif [[ -n "${APPLE_CERTIFICATE_PASSWORD:-}" || -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
            printf '%s\n' 'Incomplete Apple signing configuration: provide APPLE_CERTIFICATE, or remove the password and identity.' >&2
            exit 1
        else
            printf '%s\n' 'No Apple signing certificate is configured; the package is unsigned.'
            SIGN_ARGS=(--no-sign)
        fi
        ;;
    windows)
        if [[ "$ARCH" != "amd64" ]]; then
            printf '%s\n' 'Windows packaging supports amd64 only.' >&2
            exit 2
        fi
        if [[ -n "${WINDOWS_CERTIFICATE:-}" && -n "${WINDOWS_CERTIFICATE_PASSWORD:-}" ]]; then
            SIGNED=1
        elif [[ -n "${WINDOWS_CERTIFICATE:-}" || -n "${WINDOWS_CERTIFICATE_PASSWORD:-}" ]]; then
            printf '%s\n' 'Incomplete Windows signing configuration: provide both WINDOWS_CERTIFICATE and WINDOWS_CERTIFICATE_PASSWORD, or neither.' >&2
            exit 1
        else
            # A timestamp server alone signs nothing, so it does not count as a partial configuration.
            printf '%s\n' 'No Windows signing certificate is configured; the package is unsigned.'
            SIGN_ARGS=(--no-sign)
        fi
        ;;
    linux) ;;
    *) printf '%s\n' "Desktop packages are not supported on host OS $GOOS." >&2; exit 2 ;;
esac

OUT_DIR="$ROOT_DIR/dist/desktop/$GOOS-$ARCH"
OUT_RELATIVE="dist/desktop/$GOOS-$ARCH"
ARTIFACT_PATHS=()
EXPECTED_VERSION_LINE="version = \"$VERSION\""

contains_version_line() {
    strings -a "$1" | grep -Fqx -- "$EXPECTED_VERSION_LINE"
}

# is_stable_program says the program was built with the lithe_stable tag, so it shows the plain
# version rather than a preview; go version -m reads the build settings Go records in every binary.
is_stable_program() {
    go version -m "$1" | awk '$1 == "build" && $2 ~ /^-tags=/ {
        n = split(substr($2, 7), tags, ",")
        for (i = 1; i <= n; i++) if (tags[i] == "lithe_stable") found = 1
    } END { exit !found }'
}

write_checksum() {
    local artifact_name="$1"
    (
        cd "$OUT_DIR"
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$artifact_name" > "$artifact_name.sha256"
            shasum -a 256 -c "$artifact_name.sha256"
        elif command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$artifact_name" > "$artifact_name.sha256"
            sha256sum -c "$artifact_name.sha256"
        else
            printf '%s\n' 'Neither shasum nor sha256sum is available.' >&2
            exit 1
        fi
    )
    ARTIFACT_PATHS+=("$OUT_RELATIVE/$artifact_name" "$OUT_RELATIVE/$artifact_name.sha256")
}

case "$GOOS" in
    darwin)
        APPLE_ARGS=(--arch "$ARCH" --format 'app,zip,dmg' --out "$OUT_DIR" --stable)
        APPLE_ARGS+=("${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}")
        "$ROOT_DIR/scripts/desktop/package-desktop.sh" "${APPLE_ARGS[@]+"${APPLE_ARGS[@]}"}"

        APP="$OUT_DIR/Lithe Desktop.app"
        STEM="lithe-$VERSION-darwin-$ARCH"
        PLIST="$APP/Contents/Info.plist"
        BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
        if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
            printf '%s\n' "The bundle says version $BUNDLE_VERSION, not $VERSION." >&2
            exit 1
        fi
        EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
        PROGRAM="$APP/Contents/MacOS/$EXECUTABLE"
        lipo "$PROGRAM" -verify_arch "$MACHINE_ARCH"
        if ! contains_version_line "$PROGRAM"; then
            printf '%s\n' "The program does not carry $EXPECTED_VERSION_LINE from viva.toml." >&2
            exit 1
        fi
        if ! is_stable_program "$PROGRAM"; then
            printf '%s\n' 'The program was not built as the stable release (no lithe_stable build tag).' >&2
            exit 1
        fi
        if [[ "$SIGNED" == 1 ]]; then
            codesign --verify --deep --strict "$APP"
        fi
        # diskutil image replaces the deprecated hdiutil imageinfo, which older runners still need.
        diskutil image info "$OUT_DIR/$STEM.dmg" > /dev/null 2>&1 || hdiutil imageinfo "$OUT_DIR/$STEM.dmg" > /dev/null
        for archive in "$STEM.zip" "$STEM.dmg"; do
            if [[ ! -s "$OUT_DIR/$archive" ]]; then
                printf '%s\n' "The package is missing or empty: $OUT_DIR/$archive" >&2
                exit 1
            fi
            write_checksum "$archive"
        done
        ;;
    windows)
        STEM="lithe-$VERSION-windows-$ARCH"
        "$ROOT_DIR/scripts/desktop/package-desktop.sh" --arch "$ARCH" --format nsis,zip --out "$OUT_DIR" --stable \
            "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}"

        INSTALLER="$OUT_DIR/$STEM-setup.exe"
        ZIP="$OUT_DIR/$STEM.zip"
        if [[ ! -s "$INSTALLER" || ! -s "$ZIP" ]]; then
            printf '%s\n' 'The Windows installer or zip is missing or empty.' >&2
            exit 1
        fi
        if ! unzip -l "$ZIP" | awk '$NF == "lithe.exe" { found = 1 } END { exit !found }'; then
            printf '%s\n' "The Windows archive does not contain lithe.exe: $ZIP" >&2
            exit 1
        fi
        VERIFY_DIR="$(mktemp -d "$OUT_DIR/.lithe-verify.XXXXXX")"
        trap 'rm -rf -- "$VERIFY_DIR"' EXIT
        EXTRACTED_PROGRAM="$VERIFY_DIR/lithe.exe"
        unzip -p "$ZIP" lithe.exe > "$EXTRACTED_PROGRAM"
        if [[ ! -s "$EXTRACTED_PROGRAM" ]] || ! contains_version_line "$EXTRACTED_PROGRAM"; then
            printf '%s\n' "The extracted Windows program does not carry $EXPECTED_VERSION_LINE." >&2
            exit 1
        fi
        if ! is_stable_program "$EXTRACTED_PROGRAM"; then
            printf '%s\n' 'The Windows program was not built as the stable release (no lithe_stable build tag).' >&2
            exit 1
        fi
        if [[ "$SIGNED" == 1 ]]; then
            WINDOWS_PROGRAM_PATH="$(native_path "$EXTRACTED_PROGRAM")"
            WINDOWS_INSTALLER_PATH="$(native_path "$INSTALLER")"
            export WINDOWS_PROGRAM_PATH WINDOWS_INSTALLER_PATH
            powershell.exe -NoProfile -NonInteractive -Command '
                $ErrorActionPreference = "Stop"
                foreach ($path in @($env:WINDOWS_PROGRAM_PATH, $env:WINDOWS_INSTALLER_PATH)) {
                    $signature = Get-AuthenticodeSignature -FilePath $path
                    if ($signature.Status -ne "Valid") {
                        [Console]::Error.WriteLine("{0} has Authenticode status {1}.", $path, $signature.Status)
                        exit 1
                    }
                }
                exit 0
            '
            unset WINDOWS_PROGRAM_PATH WINDOWS_INSTALLER_PATH
        fi
        write_checksum "$STEM-setup.exe"
        write_checksum "$STEM.zip"
        ;;
    linux)
        if [[ "$ARCH" == "amd64" ]]; then
            DEB_ARCH="amd64"
            EXPECTED_MACHINE="x86-64"
        else
            DEB_ARCH="arm64"
            EXPECTED_MACHINE="aarch64"
        fi
        STEM="lithe-$VERSION-linux-$ARCH"
        DEB_NAME="lithe_${VERSION}_${DEB_ARCH}.deb"
        "$ROOT_DIR/scripts/desktop/package-desktop.sh" --arch "$ARCH" --format tar.gz,deb --out "$OUT_DIR" --stable

        TARBALL="$OUT_DIR/$STEM.tar.gz"
        DEB="$OUT_DIR/$DEB_NAME"
        if [[ ! -s "$TARBALL" || ! -s "$DEB" ]]; then
            printf '%s\n' 'The Linux tarball or Debian package is missing or empty.' >&2
            exit 1
        fi
        if ! tar -tzf "$TARBALL" | awk -v program="$STEM/lithe" '$0 == program { found = 1 } END { exit !found }'; then
            printf '%s\n' "The Linux archive does not contain $STEM/lithe." >&2
            exit 1
        fi
        VERIFY_DIR="$(mktemp -d "$OUT_DIR/.lithe-verify.XXXXXX")"
        trap 'rm -rf -- "$VERIFY_DIR"' EXIT
        EXTRACTED_PROGRAM="$VERIFY_DIR/lithe"
        tar -xOzf "$TARBALL" "$STEM/lithe" > "$EXTRACTED_PROGRAM"
        if [[ ! -s "$EXTRACTED_PROGRAM" ]]; then
            printf '%s\n' 'The extracted Linux program is empty.' >&2
            exit 1
        fi
        PROGRAM_FILE="$(file "$EXTRACTED_PROGRAM")"
        printf '%s\n' "$PROGRAM_FILE"
        if [[ "$PROGRAM_FILE" != *ELF* || "$PROGRAM_FILE" != *"$EXPECTED_MACHINE"* ]]; then
            printf '%s\n' "The Linux program is not an ELF for $EXPECTED_MACHINE." >&2
            exit 1
        fi
        if ! contains_version_line "$EXTRACTED_PROGRAM"; then
            printf '%s\n' "The extracted Linux program does not carry $EXPECTED_VERSION_LINE." >&2
            exit 1
        fi
        if ! is_stable_program "$EXTRACTED_PROGRAM"; then
            printf '%s\n' 'The Linux program was not built as the stable release (no lithe_stable build tag).' >&2
            exit 1
        fi
        DEB_VERSION="$(dpkg-deb -f "$DEB" Version)"
        DEB_ARCHITECTURE="$(dpkg-deb -f "$DEB" Architecture)"
        if [[ "$DEB_VERSION" != "$VERSION" ]]; then
            printf '%s\n' "The Debian package says version $DEB_VERSION, not $VERSION." >&2
            exit 1
        fi
        if [[ "$DEB_ARCHITECTURE" != "$DEB_ARCH" ]]; then
            printf '%s\n' "The Debian package says architecture $DEB_ARCHITECTURE, not $DEB_ARCH." >&2
            exit 1
        fi
        write_checksum "$STEM.tar.gz"
        write_checksum "$DEB_NAME"
        ;;
esac

printf '%s\n' "${ARTIFACT_PATHS[@]+"${ARTIFACT_PATHS[@]}"}"
