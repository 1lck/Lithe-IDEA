#!/usr/bin/env bash
#
# Stages the bundled JDT LS distribution for Linux. Mirrors
# scripts/prepare-jdtls.sh (macOS): same downloads, checksums and output
# layout (plugins/, config_linux/, lombok/, java-debug/, java-test/), so the
# packaged runtime is identical in structure across platforms.

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/third_party/jdtls/manifest.json"
OUTPUT_DIR="${LITHE_JDTLS_ROOT:-$ROOT_DIR/.artifacts/jdtls-linux}"
CACHE_DIR="$ROOT_DIR/.artifacts/jdtls-downloads"

manifest_value() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$MANIFEST" "$1"
}

jdtls_version="$(manifest_value version)"
archive_url="$(manifest_value archiveURL)"
archive_sha256="$(manifest_value archiveSHA256)"
license_url="$(manifest_value licenseURL)"
license_sha256="$(manifest_value licenseSHA256)"
lombok_url="$(manifest_value lombokURL)"
lombok_sha256="$(manifest_value lombokSHA256)"
lombok_license_url="$(manifest_value lombokLicenseURL)"
lombok_license_sha256="$(manifest_value lombokLicenseSHA256)"
java_debug_archive_url="$(manifest_value javaDebugArchiveURL)"
java_debug_archive_sha256="$(manifest_value javaDebugArchiveSHA256)"
java_debug_plugin_sha256="$(manifest_value javaDebugPluginSHA256)"
java_debug_license_url="$(manifest_value javaDebugLicenseURL)"
java_debug_license_sha256="$(manifest_value javaDebugLicenseSHA256)"
java_debug_extension_version="$(manifest_value javaDebugExtensionVersion)"
java_debug_server_version="$(manifest_value javaDebugServerVersion)"
java_test_archive_url="$(manifest_value javaTestArchiveURL)"
java_test_archive_sha256="$(manifest_value javaTestArchiveSHA256)"
java_test_plugin_sha256="$(manifest_value javaTestPluginSHA256)"
java_test_runner_sha256="$(manifest_value javaTestRunnerSHA256)"
java_test_license_url="$(manifest_value javaTestLicenseURL)"
java_test_license_sha256="$(manifest_value javaTestLicenseSHA256)"
java_test_extension_version="$(manifest_value javaTestExtensionVersion)"
java_test_plugin_version="$(manifest_value javaTestPluginVersion)"
lombok_version="$(manifest_value lombokVersion)"

archive_path="$CACHE_DIR/jdtls-$jdtls_version-$archive_sha256.tar.gz"
license_path="$CACHE_DIR/EPL-2.0-$license_sha256.txt"
lombok_path="$CACHE_DIR/lombok-$lombok_version-$lombok_sha256.jar"
lombok_license_path="$CACHE_DIR/lombok-MIT-$lombok_version-$lombok_license_sha256.txt"
java_debug_archive_path="$CACHE_DIR/vscode-java-debug-$java_debug_extension_version-$java_debug_archive_sha256.vsix"
java_debug_license_path="$CACHE_DIR/java-debug-EPL-1.0-$java_debug_server_version-$java_debug_license_sha256.txt"
java_debug_plugin_name="com.microsoft.java.debug.plugin-$java_debug_server_version.jar"
java_test_archive_path="$CACHE_DIR/vscode-java-test-$java_test_extension_version-$java_test_archive_sha256.vsix"
java_test_license_path="$CACHE_DIR/java-test-MIT-$java_test_extension_version-$java_test_license_sha256.txt"
java_test_plugin_name="com.microsoft.java.test.plugin-$java_test_plugin_version.jar"
java_test_runner_name="com.microsoft.java.test.runner-jar-with-dependencies.jar"
java_test_bundle_list="java-test/extensions.txt"

file_sha256() {
    sha256sum "$1" | awk '{print tolower($1)}'
}

download_verified_file() {
    local url="$1" expected="$2" destination="$3" description="$4"
    if [[ -f "$destination" ]] && [[ "$(file_sha256 "$destination")" == "$expected" ]]; then
        return 0
    fi
    rm -f -- "$destination"
    echo "Downloading $description: $url" >&2
    curl --fail --location --retry 3 --retry-all-errors \
        --connect-timeout 15 --max-time 300 \
        --output "$destination.download.$$" "$url"
    local actual
    actual="$(file_sha256 "$destination.download.$$")"
    if [[ "$actual" != "$expected" ]]; then
        echo "$description checksum mismatch: expected $expected, got $actual" >&2
        rm -f -- "$destination.download.$$"
        exit 1
    fi
    mv -f -- "$destination.download.$$" "$destination"
}

validate_output() {
    [[ -d "$OUTPUT_DIR/plugins" ]] || { echo "JDTLS plugins directory is missing: $OUTPUT_DIR" >&2; exit 1; }
    compgen -G "$OUTPUT_DIR/plugins/org.eclipse.equinox.launcher_*.jar" >/dev/null || {
        echo "JDTLS Equinox launcher is missing: $OUTPUT_DIR/plugins" >&2; exit 1; }
    [[ -d "$OUTPUT_DIR/config_linux" ]] || { echo "JDTLS Linux configuration is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/lombok/lombok.jar" ]] || { echo "JDTLS Lombok agent is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-debug/$java_debug_plugin_name" ]] || { echo "Java Debug Server plugin is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-test/extensions/$java_test_plugin_name" ]] || { echo "Java Test extension plugin is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-test/runner/$java_test_runner_name" ]] || { echo "Java Test runner is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/$java_test_bundle_list" ]] || { echo "Java Test bundle list is missing: $OUTPUT_DIR/$java_test_bundle_list" >&2; exit 1; }
    local bundle
    while read -r bundle; do
        [[ -n "$bundle" ]] || continue
        [[ -f "$OUTPUT_DIR/java-test/extensions/$bundle" ]] || {
            echo "Java Test bundle $bundle is missing: $OUTPUT_DIR/java-test/extensions" >&2; exit 1; }
    done < "$OUTPUT_DIR/$java_test_bundle_list"
}

if [[ -d "$OUTPUT_DIR" ]] && validate_output 2>/dev/null; then
    echo "$OUTPUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR"
download_verified_file "$archive_url" "$archive_sha256" "$archive_path" "JDTLS archive"
download_verified_file "$license_url" "$license_sha256" "$license_path" "EPL-2.0 license"
download_verified_file "$lombok_url" "$lombok_sha256" "$lombok_path" "Lombok agent"
download_verified_file "$lombok_license_url" "$lombok_license_sha256" "$lombok_license_path" "Lombok MIT license"
download_verified_file "$java_debug_archive_url" "$java_debug_archive_sha256" "$java_debug_archive_path" "Java Debug extension"
download_verified_file "$java_debug_license_url" "$java_debug_license_sha256" "$java_debug_license_path" "Java Debug EPL-1.0 license"
download_verified_file "$java_test_archive_url" "$java_test_archive_sha256" "$java_test_archive_path" "Java Test extension"
download_verified_file "$java_test_license_url" "$java_test_license_sha256" "$java_test_license_path" "Java Test MIT license"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
tar -xzf "$archive_path" -C "$OUTPUT_DIR"
cp "$license_path" "$OUTPUT_DIR/LICENSE-EPL-2.0.txt"
cp "$MANIFEST" "$OUTPUT_DIR/manifest.json"

mkdir -p "$OUTPUT_DIR/lombok"
cp "$lombok_path" "$OUTPUT_DIR/lombok/lombok.jar"
cp "$lombok_license_path" "$OUTPUT_DIR/lombok/LICENSE-MIT.txt"

mkdir -p "$OUTPUT_DIR/java-debug"
unzip -p "$java_debug_archive_path" "extension/server/$java_debug_plugin_name" \
    > "$OUTPUT_DIR/java-debug/$java_debug_plugin_name"
actual_java_debug_plugin_sha256="$(file_sha256 "$OUTPUT_DIR/java-debug/$java_debug_plugin_name")"
if [[ "$actual_java_debug_plugin_sha256" != "$java_debug_plugin_sha256" ]]; then
    echo "Java Debug Server plugin checksum mismatch: expected $java_debug_plugin_sha256, got $actual_java_debug_plugin_sha256" >&2
    exit 1
fi
cp "$java_debug_license_path" "$OUTPUT_DIR/java-debug/LICENSE-EPL-1.0.txt"

java_test_extraction="$(mktemp -d "$CACHE_DIR/java-test-extract.XXXXXX")"
unzip -q "$java_test_archive_path" "extension/package.json" "extension/server/*.jar" -d "$java_test_extraction"
mkdir -p "$OUTPUT_DIR/java-test/extensions" "$OUTPUT_DIR/java-test/runner"
# Same upstream-bundle rules as prepare-jdtls.sh: copy exactly the bundles the
# Java Test extension declares, skipping ones JDT LS already ships.
: > "$OUTPUT_DIR/$java_test_bundle_list"
python3 - "$java_test_extraction/extension/package.json" > "$OUTPUT_DIR/java-test/bundle-list.txt" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for entry in data.get("contributes", {}).get("javaExtensions", []):
    print(entry)
PY
while read -r bundle_rel; do
    [[ -n "$bundle_rel" ]] || continue
    bundle_name="$(basename "$bundle_rel")"
    [[ -e "$OUTPUT_DIR/plugins/$bundle_name" ]] && continue
    cp "$java_test_extraction/extension/${bundle_rel#./}" "$OUTPUT_DIR/java-test/extensions/$bundle_name"
    printf '%s\n' "$bundle_name" >> "$OUTPUT_DIR/$java_test_bundle_list"
done < "$OUTPUT_DIR/java-test/bundle-list.txt"
rm -f "$OUTPUT_DIR/java-test/bundle-list.txt"
[[ -s "$OUTPUT_DIR/$java_test_bundle_list" ]] || { echo "Java Test extension declares no JDT LS bundles" >&2; exit 1; }
cp "$java_test_extraction/extension/server/$java_test_runner_name" "$OUTPUT_DIR/java-test/runner/$java_test_runner_name"
rm -rf -- "$java_test_extraction"

actual_java_test_plugin_sha256="$(file_sha256 "$OUTPUT_DIR/java-test/extensions/$java_test_plugin_name")"
if [[ "$actual_java_test_plugin_sha256" != "$java_test_plugin_sha256" ]]; then
    echo "Java Test plugin checksum mismatch: expected $java_test_plugin_sha256, got $actual_java_test_plugin_sha256" >&2
    exit 1
fi
actual_java_test_runner_sha256="$(file_sha256 "$OUTPUT_DIR/java-test/runner/$java_test_runner_name")"
if [[ "$actual_java_test_runner_sha256" != "$java_test_runner_sha256" ]]; then
    echo "Java Test runner checksum mismatch: expected $java_test_runner_sha256, got $actual_java_test_runner_sha256" >&2
    exit 1
fi
cp "$java_test_license_path" "$OUTPUT_DIR/java-test/LICENSE-MIT.txt"

validate_output
echo "$OUTPUT_DIR"
