#!/usr/bin/env bash
#
# Stages the bundled JDTLS runtime JDK for Linux into an architecture-specific
# artifact directory. Mirrors scripts/prepare-jdk.sh (macOS) and
# scripts/prepare-jdk.ps1-style Windows output: the directory content is a
# plain JDK home. This JDK only runs the Java language server.

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/third_party/jdk/manifest.json"
CACHE_DIR="$ROOT_DIR/.artifacts/jdk-downloads"
TARGET_ARCH="${LITHE_JDK_TARGET_ARCH:-$(uname -m)}"
OUTPUT_DIR="${LITHE_JDK_ROOT:-$ROOT_DIR/.artifacts/jdk-$TARGET_ARCH}"

manifest_value() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d
for k in sys.argv[2].split("."): p=p[k]
print(p)' "$MANIFEST" "$1"
}

case "$TARGET_ARCH" in
    x86_64) platform="linux-x86_64" ;;
    *) echo "Unsupported Linux JDK target architecture: $TARGET_ARCH" >&2; exit 1 ;;
esac

jdk_version="$(manifest_value version)"
archive_url="$(manifest_value "platforms.$platform.url")"
archive_sha256="$(manifest_value "platforms.$platform.sha256")"
jdk_root="$(manifest_value "platforms.$platform.jdkRoot")"
safe_jdk_version="${jdk_version//[^A-Za-z0-9._-]/_}"
archive_path="$CACHE_DIR/jdk-$safe_jdk_version-$platform-$archive_sha256.tar.gz"
identity="$jdk_version|$platform|$archive_sha256"
identity_path="$OUTPUT_DIR/.lithe-jdk"

file_sha256() {
    sha256sum "$1" | awk '{print tolower($1)}'
}

validate_output() {
    [[ -x "$OUTPUT_DIR/bin/java" ]] || { echo "Bundled JDK java executable is missing: $OUTPUT_DIR/bin/java" >&2; exit 1; }
    [[ -d "$OUTPUT_DIR/lib" ]] || { echo "Bundled JDK lib directory is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/release" ]] || { echo "Bundled JDK release metadata is missing: $OUTPUT_DIR/release" >&2; exit 1; }
    grep -Eq '^JAVA_VERSION="21\.' "$OUTPUT_DIR/release" || {
        echo "Bundled JDK release metadata does not report Java 21: $OUTPUT_DIR/release" >&2
        exit 1
    }
    [[ "$(cat "$identity_path" 2>/dev/null || true)" == "$identity" ]] || {
        echo "Bundled JDK identity stamp is missing or stale: $identity_path" >&2
        exit 1
    }
}

if [[ -d "$OUTPUT_DIR" ]] && validate_output 2>/dev/null; then
    echo "$OUTPUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR"
if [[ ! -f "$archive_path" ]] || [[ "$(file_sha256 "$archive_path")" != "$archive_sha256" ]]; then
    rm -f -- "$archive_path"
    echo "Downloading bundled JDK ($platform): $archive_url" >&2
    curl --fail --location --retry 3 --retry-all-errors \
        --connect-timeout 15 --max-time 600 \
        --output "$archive_path.download.$$" "$archive_url"
    mv -f -- "$archive_path.download.$$" "$archive_path"
fi
actual_sha256="$(file_sha256 "$archive_path")"
if [[ "$actual_sha256" != "$archive_sha256" ]]; then
    echo "Bundled JDK checksum mismatch: expected $archive_sha256, got $actual_sha256" >&2
    exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
tar -xzf "$archive_path" -C "$OUTPUT_DIR" --strip-components=1 -- "$jdk_root/"
printf '%s' "$identity" > "$identity_path"

validate_output
echo "$OUTPUT_DIR"
