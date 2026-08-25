#!/bin/zsh

# Stages the bundled JDTLS runtime JDK into .artifacts/jdk.
# This JDK only runs the Java language server. Project SDKs stay user-owned.

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
MANIFEST="$ROOT_DIR/third_party/jdk/manifest.json"
OUTPUT_DIR="${LITHE_JDK_ROOT:-$ROOT_DIR/.artifacts/jdk}"
CACHE_DIR="$ROOT_DIR/.artifacts/jdk-downloads"

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

case "$(uname -m)" in
    arm64) platform="macos-aarch64" ;;
    x86_64) platform="macos-x86_64" ;;
    *) print -u2 -- "Unsupported macOS architecture: $(uname -m)"; exit 1 ;;
esac

jdk_version="$(manifest_value version)"
archive_url="$(manifest_value "platforms.$platform.url")"
archive_sha256="$(manifest_value "platforms.$platform.sha256")"
archive_path="$CACHE_DIR/jdk-$jdk_version-$platform-$archive_sha256.tar.gz"

file_sha256() {
    shasum -a 256 "$1" | awk '{print tolower($1)}'
}

download_verified_file() {
    local url="$1"
    local expected_sha256="$2"
    local destination="$3"
    local description="$4"
    local actual_sha256
    local temporary_path="$destination.download.$$"

    if [[ -f "$destination" ]]; then
        actual_sha256="$(file_sha256 "$destination")"
        if [[ "$actual_sha256" == "$expected_sha256" ]]; then
            return 0
        fi
        print -u2 -- "$description cache checksum mismatch; removing it before retrying the download"
        rm -f -- "$destination"
    fi

    rm -f -- "$temporary_path"
    if ! curl --fail --location --retry 3 --output "$temporary_path" "$url"; then
        rm -f -- "$temporary_path"
        return 1
    fi
    actual_sha256="$(file_sha256 "$temporary_path")"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        print -u2 -- "$description checksum mismatch: expected $expected_sha256, got $actual_sha256"
        rm -f -- "$temporary_path"
        return 1
    fi
    mv -f -- "$temporary_path" "$destination"
}

validate_output() {
    [[ -x "$OUTPUT_DIR/bin/java" ]] || { print -u2 -- "Bundled JDK java executable is missing: $OUTPUT_DIR/bin/java"; exit 1; }
    [[ -d "$OUTPUT_DIR/lib" ]] || { print -u2 -- "Bundled JDK lib directory is missing: $OUTPUT_DIR"; exit 1; }
    local reported_version
    reported_version="$("$OUTPUT_DIR/bin/java" -version 2>&1 | head -n 1)"
    case "$reported_version" in
        *\"21.*) ;;
        *) print -u2 -- "Bundled JDK reported an unexpected version: $reported_version"; exit 1 ;;
    esac
}

if [[ -n "${LITHE_JDK_ROOT:-}" ]]; then
    validate_output
    print -r -- "$OUTPUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR"
download_verified_file "$archive_url" "$archive_sha256" "$archive_path" "Temurin JDK archive"

rm -rf "$OUTPUT_DIR"
staging="$CACHE_DIR/staging.$$"
rm -rf "$staging"
mkdir -p "$staging"
tar -xzf "$archive_path" -C "$staging"

# macOS Temurin archives nest the runtime under <release>/Contents/Home.
# Flatten it so both platforms expose the same bin/java layout.
home_directory="$(find "$staging" -maxdepth 3 -type d -name Home -path '*/Contents/Home' -print | head -n 1)"
if [[ -z "$home_directory" ]]; then
    print -u2 -- "Could not locate Contents/Home in the Temurin archive"
    rm -rf "$staging"
    exit 1
fi
mkdir -p "$(dirname "$OUTPUT_DIR")"
mv "$home_directory" "$OUTPUT_DIR"
rm -rf "$staging"

validate_output
print -r -- "$OUTPUT_DIR"
