#!/bin/zsh

# Stages the bundled JDTLS runtime JDK into an architecture-specific artifact directory.
# This JDK only runs the Java language server. Project SDKs stay user-owned.

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
MANIFEST="$ROOT_DIR/third_party/jdk/manifest.json"
CACHE_DIR="$ROOT_DIR/.artifacts/jdk-downloads"
TARGET_ARCH="${LITHE_JDK_TARGET_ARCH:-$(uname -m)}"
OUTPUT_DIR="${LITHE_JDK_ROOT:-$ROOT_DIR/.artifacts/jdk-$TARGET_ARCH}"

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

case "$TARGET_ARCH" in
    arm64) platform="macos-aarch64" ;;
    x86_64) platform="macos-x86_64" ;;
    *) print -u2 -- "Unsupported macOS JDK target architecture: $TARGET_ARCH"; exit 1 ;;
esac

jdk_version="$(manifest_value version)"
archive_url="$(manifest_value "platforms.$platform.url")"
archive_sha256="$(manifest_value "platforms.$platform.sha256")"
safe_jdk_version="${jdk_version//[^A-Za-z0-9._-]/_}"
archive_path="$CACHE_DIR/jdk-$safe_jdk_version-$platform-$archive_sha256.tar.gz"
identity="$jdk_version|$platform|$archive_sha256"
identity_path="$OUTPUT_DIR/.lithe-jdk"

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
    print -u2 -- "Downloading $description: $url"
    if ! curl \
        --fail \
        --location \
        --retry 3 \
        --retry-all-errors \
        --connect-timeout 15 \
        --max-time 180 \
        --output "$temporary_path" \
        "$url"; then
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
    /usr/bin/lipo "$OUTPUT_DIR/bin/java" -verify_arch "$TARGET_ARCH" >/dev/null 2>&1 || {
        print -u2 -- "Bundled JDK java executable does not contain $TARGET_ARCH: $OUTPUT_DIR/bin/java"
        exit 1
    }
    [[ -f "$OUTPUT_DIR/release" ]] || { print -u2 -- "Bundled JDK release metadata is missing: $OUTPUT_DIR/release"; exit 1; }
    grep -Eq '^JAVA_VERSION="21\.' "$OUTPUT_DIR/release" || {
        print -u2 -- "Bundled JDK release metadata does not report Java 21: $OUTPUT_DIR/release"
        exit 1
    }
}

output_is_valid() {
    [[ -x "$OUTPUT_DIR/bin/java" ]] &&
        [[ -d "$OUTPUT_DIR/lib" ]] &&
        [[ -f "$OUTPUT_DIR/release" ]] &&
        /usr/bin/lipo "$OUTPUT_DIR/bin/java" -verify_arch "$TARGET_ARCH" >/dev/null 2>&1 &&
        grep -Eq '^JAVA_VERSION="21\.' "$OUTPUT_DIR/release"
}

if [[ -n "${LITHE_JDK_ROOT:-}" ]]; then
    validate_output
    print -r -- "$OUTPUT_DIR"
    exit 0
fi

if [[ -f "$identity_path" && "$(<"$identity_path")" == "$identity" ]]; then
    if output_is_valid; then
        print -r -- "$OUTPUT_DIR"
        exit 0
    fi
    print -u2 -- "Prepared bundled JDK is invalid and will be rebuilt: $OUTPUT_DIR"
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
print -r -- "$identity" > "$identity_path"
rm -rf "$staging"

validate_output
print -r -- "$OUTPUT_DIR"
