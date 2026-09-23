#!/usr/bin/env bash

# Stages the bundled JDTLS runtime JDK for Linux into an architecture-specific
# artifact directory. This JDK only runs the Java language server. Project SDKs
# stay user-owned.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/third_party/jdk/manifest.json"
CACHE_DIR="$ROOT_DIR/.artifacts/jdk-downloads"
TARGET_ARCH="$(uname -m)"
OUTPUT_DIR="${LITHE_JDK_ROOT:-$ROOT_DIR/.artifacts/jdk-linux}"

manifest_value() {
    python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    data = data[key]
print(data)
' "$MANIFEST" "$1"
}

case "$TARGET_ARCH" in
    x86_64 | amd64) platform="linux-x86_64" ;;
    aarch64 | arm64) platform="linux-aarch64" ;;
    *)
        echo "Unsupported Linux JDK target architecture: $TARGET_ARCH" >&2
        exit 1
        ;;
esac

jdk_version="$(manifest_value version)"
archive_url="$(manifest_value "platforms.$platform.url")"
archive_sha256="$(manifest_value "platforms.$platform.sha256")"
safe_jdk_version="${jdk_version//[^A-Za-z0-9._-]/_}"
archive_path="$CACHE_DIR/jdk-$safe_jdk_version-$platform-$archive_sha256.tar.gz"
identity="$jdk_version|$platform|$archive_sha256"
identity_path="$OUTPUT_DIR/.lithe-jdk"

file_sha256() {
    sha256sum "$1" | awk '{print tolower($1)}'
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
        echo "$description cache checksum mismatch; removing it before retrying the download" >&2
        rm -f -- "$destination"
    fi

    rm -f -- "$temporary_path"
    echo "Downloading $description: $url" >&2
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
        echo "$description checksum mismatch: expected $expected_sha256, got $actual_sha256" >&2
        rm -f -- "$temporary_path"
        return 1
    fi
    mv -f -- "$temporary_path" "$destination"
}

validate_output() {
    [[ -x "$OUTPUT_DIR/bin/java" ]] || { echo "Bundled JDK java executable is missing: $OUTPUT_DIR/bin/java" >&2; exit 1; }
    [[ -d "$OUTPUT_DIR/lib" ]] || { echo "Bundled JDK lib directory is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/release" ]] || { echo "Bundled JDK release metadata is missing: $OUTPUT_DIR/release" >&2; exit 1; }
    grep -Eq '^JAVA_VERSION="21\.' "$OUTPUT_DIR/release" || {
        echo "Bundled JDK release metadata does not report Java 21: $OUTPUT_DIR/release" >&2
        exit 1
    }
}

output_is_valid() {
    [[ -x "$OUTPUT_DIR/bin/java" ]] &&
        [[ -d "$OUTPUT_DIR/lib" ]] &&
        [[ -f "$OUTPUT_DIR/release" ]] &&
        grep -Eq '^JAVA_VERSION="21\.' "$OUTPUT_DIR/release"
}

if [[ -n "${LITHE_JDK_ROOT:-}" ]]; then
    validate_output
    printf '%s\n' "$OUTPUT_DIR"
    exit 0
fi

if [[ -f "$identity_path" && "$(<"$identity_path")" == "$identity" ]]; then
    if output_is_valid; then
        printf '%s\n' "$OUTPUT_DIR"
        exit 0
    fi
    echo "Prepared bundled JDK is invalid and will be rebuilt: $OUTPUT_DIR" >&2
fi

mkdir -p "$CACHE_DIR"
download_verified_file "$archive_url" "$archive_sha256" "$archive_path" "Temurin JDK archive"

rm -rf "$OUTPUT_DIR"
staging="$CACHE_DIR/staging.$$"
rm -rf "$staging"
mkdir -p "$staging"
tar -xzf "$archive_path" -C "$staging"

# Linux Temurin archives contain a single top-level JDK directory; move it to
# the final output path so bin/java and lib live directly under OUTPUT_DIR.
inner_directory="$(find "$staging" -mindepth 1 -maxdepth 1 -type d -print | head -n 1)"
if [[ -z "$inner_directory" ]]; then
    echo "Could not locate the JDK directory in the Temurin archive" >&2
    rm -rf "$staging"
    exit 1
fi
mkdir -p "$(dirname "$OUTPUT_DIR")"
mv "$inner_directory" "$OUTPUT_DIR"
# The Temurin archive marks some files read-only. Tauri copies bundle resources
# with their permissions, so a second build could not overwrite the read-only
# copies under target/ and failed with "Permission denied". Make the staged tree
# writable so repeated packaging works.
chmod -R u+w "$OUTPUT_DIR"
printf '%s\n' "$identity" > "$identity_path"
rm -rf "$staging"

validate_output
printf '%s\n' "$OUTPUT_DIR"
