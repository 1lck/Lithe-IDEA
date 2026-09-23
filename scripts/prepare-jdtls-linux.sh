#!/usr/bin/env bash

# Stages the bundled JDTLS distribution for Linux. Unlike the macOS/Windows
# prepare scripts this reads the manifest with python3 (no plutil) and only
# requires the config_linux configuration shipped by upstream.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/third_party/jdtls/manifest.json"
JDK_MANIFEST="$ROOT_DIR/third_party/jdk/manifest.json"
OUTPUT_DIR="${LITHE_JDTLS_ROOT:-$ROOT_DIR/.artifacts/jdtls-linux}"
CACHE_DIR="$ROOT_DIR/.artifacts/jdtls-downloads"

manifest_value() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$MANIFEST" "$1"
}

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
java_test_archive_url="$(manifest_value javaTestArchiveURL)"
java_test_archive_sha256="$(manifest_value javaTestArchiveSHA256)"
java_test_plugin_sha256="$(manifest_value javaTestPluginSHA256)"
java_test_runner_sha256="$(manifest_value javaTestRunnerSHA256)"
java_test_license_url="$(manifest_value javaTestLicenseURL)"
java_test_license_sha256="$(manifest_value javaTestLicenseSHA256)"
jdtls_version="$(manifest_value version)"
lombok_version="$(manifest_value lombokVersion)"
java_debug_extension_version="$(manifest_value javaDebugExtensionVersion)"
java_debug_server_version="$(manifest_value javaDebugServerVersion)"
java_test_extension_version="$(manifest_value javaTestExtensionVersion)"
java_test_plugin_version="$(manifest_value javaTestPluginVersion)"
minimum_java_version="$(manifest_value minimumJavaVersion)"
bundled_jdk_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$JDK_MANIFEST")"
archive_path="${LITHE_JDTLS_ARCHIVE:-$CACHE_DIR/jdtls-$jdtls_version-$archive_sha256.tar.gz}"
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
# Records the Java Test bundle set declared by the extension so validation
# checks the exact upstream list instead of a hard-coded count.
java_test_bundle_list="java-test/extensions.txt"

# JDT LS refuses to start on a Java runtime older than it requires, and the
# bundled JDK is the runtime Lithe launches it with.
if (( ${bundled_jdk_version%%.*} < minimum_java_version )); then
    echo "Bundled JDK $bundled_jdk_version is older than the Java $minimum_java_version that JDTLS $jdtls_version requires" >&2
    exit 1
fi

file_sha256() {
    sha256sum "$1" | awk '{print tolower($1)}'
}

cache_warning() {
    local message="$1"
    echo "warning: $message" >&2
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        message="${message//'%'/'%25'}"
        message="${message//$'\r'/'%0D'}"
        message="${message//$'\n'/'%0A'}"
        echo "::warning title=JDTLS cache fallback::$message"
    fi
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
        cache_warning "$description cache checksum mismatch; removing it before retrying the download"
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
    [[ -d "$OUTPUT_DIR/plugins" ]] || { echo "JDTLS plugins directory is missing: $OUTPUT_DIR" >&2; exit 1; }
    local launcher_count=0
    local candidate
    for candidate in "$OUTPUT_DIR"/plugins/org.eclipse.equinox.launcher_*.jar; do
        [[ -e "$candidate" ]] || continue
        (( launcher_count += 1 ))
    done
    [[ $launcher_count -gt 0 ]] || { echo "JDTLS Equinox launcher is missing: $OUTPUT_DIR/plugins" >&2; exit 1; }
    # Linux only needs the upstream config_linux configuration; macOS and
    # Windows configurations are not required for this artifact.
    [[ -d "$OUTPUT_DIR/config_linux" ]] || { echo "JDTLS Linux configuration is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -x "$OUTPUT_DIR/bin/jdtls" ]] || { echo "JDTLS launcher is missing: $OUTPUT_DIR/bin/jdtls" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/lombok/lombok.jar" ]] || { echo "JDTLS Lombok agent is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/lombok/LICENSE-MIT.txt" ]] || { echo "JDTLS Lombok license is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-debug/$java_debug_plugin_name" ]] || { echo "Java Debug Server plugin is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-debug/LICENSE-EPL-1.0.txt" ]] || { echo "Java Debug Server license is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-test/extensions/$java_test_plugin_name" ]] || { echo "Java Test extension plugin is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/$java_test_bundle_list" ]] || { echo "Java Test bundle list is missing: $OUTPUT_DIR/$java_test_bundle_list" >&2; exit 1; }
    local declared_bundles=()
    local declared_bundle
    while IFS= read -r declared_bundle; do
        [[ -n "$declared_bundle" ]] && declared_bundles+=("$declared_bundle")
    done < "$OUTPUT_DIR/$java_test_bundle_list"
    for declared_bundle in "${declared_bundles[@]}"; do
        [[ -f "$OUTPUT_DIR/java-test/extensions/$declared_bundle" ]] || { echo "Java Test bundle $declared_bundle is missing: $OUTPUT_DIR/java-test/extensions" >&2; exit 1; }
    done
    local java_test_extension_count=0
    for candidate in "$OUTPUT_DIR"/java-test/extensions/*.jar; do
        [[ -e "$candidate" ]] || continue
        (( java_test_extension_count += 1 ))
    done
    [[ $java_test_extension_count -eq ${#declared_bundles[@]} ]] || { echo "Java Test extension bundles do not match $java_test_bundle_list: $OUTPUT_DIR/java-test/extensions" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-test/runner/$java_test_runner_name" ]] || { echo "Java Test runner is missing: $OUTPUT_DIR" >&2; exit 1; }
    [[ -f "$OUTPUT_DIR/java-test/LICENSE-MIT.txt" ]] || { echo "Java Test license is missing: $OUTPUT_DIR" >&2; exit 1; }
}

if [[ -n "${LITHE_JDTLS_ROOT:-}" ]]; then
    validate_output
    printf '%s\n' "$OUTPUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR"
if [[ -n "${LITHE_JDTLS_ARCHIVE:-}" ]]; then
    [[ -f "$archive_path" ]] || { echo "JDTLS archive was not found: $archive_path" >&2; exit 1; }
    actual_archive_sha256="$(file_sha256 "$archive_path")"
    if [[ "$actual_archive_sha256" != "$archive_sha256" ]]; then
        echo "JDTLS archive checksum mismatch: expected $archive_sha256, got $actual_archive_sha256" >&2
        exit 1
    fi
else
    download_verified_file "$archive_url" "$archive_sha256" "$archive_path" "JDTLS archive"
fi
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
unzip -p \
    "$java_debug_archive_path" \
    "extension/server/$java_debug_plugin_name" \
    > "$OUTPUT_DIR/java-debug/$java_debug_plugin_name"
actual_java_debug_plugin_sha256="$(file_sha256 "$OUTPUT_DIR/java-debug/$java_debug_plugin_name")"
if [[ "$actual_java_debug_plugin_sha256" != "$java_debug_plugin_sha256" ]]; then
    echo "Java Debug Server plugin checksum mismatch: expected $java_debug_plugin_sha256, got $actual_java_debug_plugin_sha256" >&2
    exit 1
fi
cp "$java_debug_license_path" "$OUTPUT_DIR/java-debug/LICENSE-EPL-1.0.txt"
java_test_extraction="$(mktemp -d "$CACHE_DIR/java-test-extract.XXXXXX")"
unzip -q \
    "$java_test_archive_path" \
    "extension/package.json" \
    "extension/server/*.jar" \
    -d "$java_test_extraction"
mkdir -p "$OUTPUT_DIR/java-test/extensions" "$OUTPUT_DIR/java-test/runner"
# The extension's `contributes.javaExtensions` is the upstream list of bundles
# JDT LS must load; copying exactly that list keeps the runner and coverage
# agent out of OSGi and follows upstream when the bundle set changes.
: > "$OUTPUT_DIR/$java_test_bundle_list"
java_test_bundles="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["contributes"]["javaExtensions"]))' "$java_test_extraction/extension/package.json")"
[[ -n "$java_test_bundles" ]] || { echo "Java Test extension declares no JDT LS bundles" >&2; exit 1; }
while IFS= read -r java_test_bundle; do
    [[ -n "$java_test_bundle" ]] || continue
    cp "$java_test_extraction/extension/${java_test_bundle#./}" "$OUTPUT_DIR/java-test/extensions/$(basename -- "$java_test_bundle")"
    printf '%s\n' "$(basename -- "$java_test_bundle")" >> "$OUTPUT_DIR/$java_test_bundle_list"
done <<< "$java_test_bundles"
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
printf '%s\n' "$OUTPUT_DIR"
