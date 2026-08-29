#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
MANIFEST="$ROOT_DIR/third_party/jdtls/manifest.json"
OUTPUT_DIR="${LITHE_JDTLS_ROOT:-$ROOT_DIR/.artifacts/jdtls}"
CACHE_DIR="$ROOT_DIR/.artifacts/jdtls-downloads"

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
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
jdtls_version="$(manifest_value version)"
lombok_version="$(manifest_value lombokVersion)"
java_debug_extension_version="$(manifest_value javaDebugExtensionVersion)"
java_debug_server_version="$(manifest_value javaDebugServerVersion)"
archive_path="${LITHE_JDTLS_ARCHIVE:-$CACHE_DIR/jdtls-$jdtls_version-$archive_sha256.tar.gz}"
license_path="$CACHE_DIR/EPL-2.0-$license_sha256.txt"
lombok_path="$CACHE_DIR/lombok-$lombok_version-$lombok_sha256.jar"
lombok_license_path="$CACHE_DIR/lombok-MIT-$lombok_version-$lombok_license_sha256.txt"
java_debug_archive_path="$CACHE_DIR/vscode-java-debug-$java_debug_extension_version-$java_debug_archive_sha256.vsix"
java_debug_license_path="$CACHE_DIR/java-debug-EPL-1.0-$java_debug_server_version-$java_debug_license_sha256.txt"
java_debug_plugin_name="com.microsoft.java.debug.plugin-$java_debug_server_version.jar"

file_sha256() {
    shasum -a 256 "$1" | awk '{print tolower($1)}'
}

cache_warning() {
    local message="$1"
    print -u2 -- "warning: $message"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        message="${message//'%'/'%25'}"
        message="${message//$'\r'/'%0D'}"
        message="${message//$'\n'/'%0A'}"
        print -- "::warning title=JDTLS cache fallback::$message"
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
    [[ -d "$OUTPUT_DIR/plugins" ]] || { print -u2 -- "JDTLS plugins directory is missing: $OUTPUT_DIR"; exit 1; }
    local launcher_jars=("$OUTPUT_DIR"/plugins/org.eclipse.equinox.launcher_*.jar(N))
    (( ${#launcher_jars[@]} > 0 )) || { print -u2 -- "JDTLS Equinox launcher is missing: $OUTPUT_DIR/plugins"; exit 1; }
    local target_arch="${LITHE_ARCH:-$(uname -m)}"
    local required_mac_configurations
    case "$target_arch" in
        arm64) required_mac_configurations=(config_mac_arm) ;;
        x86_64) required_mac_configurations=(config_mac) ;;
        universal) required_mac_configurations=(config_mac_arm config_mac) ;;
        *) print -u2 -- "Unsupported JDTLS target architecture: $target_arch"; exit 1 ;;
    esac
    local configuration_name
    for configuration_name in "${required_mac_configurations[@]}"; do
        [[ -d "$OUTPUT_DIR/$configuration_name" ]] || {
            print -u2 -- "JDTLS $configuration_name configuration is missing: $OUTPUT_DIR"
            exit 1
        }
    done
    [[ -d "$OUTPUT_DIR/config_win" ]] || { print -u2 -- "JDTLS Windows configuration is missing: $OUTPUT_DIR"; exit 1; }
    [[ -x "$OUTPUT_DIR/bin/jdtls" ]] || { print -u2 -- "JDTLS launcher is missing: $OUTPUT_DIR/bin/jdtls"; exit 1; }
    [[ -f "$OUTPUT_DIR/bin/jdtls.ps1" ]] || { print -u2 -- "JDTLS Windows launcher is missing: $OUTPUT_DIR"; exit 1; }
    [[ -f "$OUTPUT_DIR/lombok/lombok.jar" ]] || { print -u2 -- "JDTLS Lombok agent is missing: $OUTPUT_DIR"; exit 1; }
    [[ -f "$OUTPUT_DIR/lombok/LICENSE-MIT.txt" ]] || { print -u2 -- "JDTLS Lombok license is missing: $OUTPUT_DIR"; exit 1; }
    [[ -f "$OUTPUT_DIR/java-debug/$java_debug_plugin_name" ]] || { print -u2 -- "Java Debug Server plugin is missing: $OUTPUT_DIR"; exit 1; }
    [[ -f "$OUTPUT_DIR/java-debug/LICENSE-EPL-1.0.txt" ]] || { print -u2 -- "Java Debug Server license is missing: $OUTPUT_DIR"; exit 1; }
    # Wrapper scripts remain available for external/legacy launch plans. The
    # packaged product launches bundled Java directly with the resources above.
    grep -Fq -- '-javaagent:' "$OUTPUT_DIR/bin/jdtls" || { print -u2 -- "JDTLS launcher does not load the Lombok agent: $OUTPUT_DIR"; exit 1; }
    grep -Fq -- '-javaagent:' "$OUTPUT_DIR/bin/jdtls.ps1" || { print -u2 -- "JDTLS Windows launcher does not load the Lombok agent: $OUTPUT_DIR"; exit 1; }
}

if [[ -n "${LITHE_JDTLS_ROOT:-}" ]]; then
    validate_output
    print -r -- "$OUTPUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR"
if [[ -n "${LITHE_JDTLS_ARCHIVE:-}" ]]; then
    [[ -f "$archive_path" ]] || { print -u2 -- "JDTLS archive was not found: $archive_path"; exit 1; }
    actual_archive_sha256="$(file_sha256 "$archive_path")"
    if [[ "$actual_archive_sha256" != "$archive_sha256" ]]; then
        print -u2 -- "JDTLS archive checksum mismatch: expected $archive_sha256, got $actual_archive_sha256"
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
    print -u2 -- "Java Debug Server plugin checksum mismatch: expected $java_debug_plugin_sha256, got $actual_java_debug_plugin_sha256"
    exit 1
fi
cp "$java_debug_license_path" "$OUTPUT_DIR/java-debug/LICENSE-EPL-1.0.txt"

cat > "$OUTPUT_DIR/bin/jdtls" <<'EOF'
#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
JAVA_EXECUTABLE="${JAVA_HOME:-}/bin/java"
if [[ ! -x "$JAVA_EXECUTABLE" ]]; then
    JAVA_EXECUTABLE="${JAVA:-java}"
fi

LOMBOK_AGENT="$SCRIPT_DIR/../lombok/lombok.jar"
[[ -f "$LOMBOK_AGENT" ]] || { print -u2 -- "JDTLS Lombok agent was not found: $LOMBOK_AGENT"; exit 1; }
JVM_ARGUMENTS=(
    "-javaagent:$LOMBOK_AGENT"
    "--add-modules=ALL-SYSTEM"
    "--add-opens=java.base/java.util=ALL-UNNAMED"
    "--add-opens=java.base/java.lang=ALL-UNNAMED"
)
SERVER_ARGUMENTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --java-executable)
            [[ $# -ge 2 ]] || { print -u2 -- "--java-executable requires a path"; exit 2; }
            JAVA_EXECUTABLE="$2"
            shift 2
            ;;
        --jvm-arg=*)
            JVM_ARGUMENTS+=("${1#--jvm-arg=}")
            shift
            ;;
        --jvm-arg)
            [[ $# -ge 2 ]] || { print -u2 -- "--jvm-arg requires a value"; exit 2; }
            JVM_ARGUMENTS+=("$2")
            shift 2
            ;;
        *)
            SERVER_ARGUMENTS+=("$1")
            shift
            ;;
    esac
done

LAUNCHER_JAR=$(find "$SCRIPT_DIR/../plugins" -maxdepth 1 -name 'org.eclipse.equinox.launcher_*.jar' -print | sort | head -n 1)
[[ -n "$LAUNCHER_JAR" ]] || { print -u2 -- "JDTLS Equinox launcher was not found"; exit 1; }
case "$(uname -m)" in
    arm64) CONFIGURATION="$SCRIPT_DIR/../config_mac_arm" ;;
    x86_64) CONFIGURATION="$SCRIPT_DIR/../config_mac" ;;
    *) print -u2 -- "Unsupported macOS architecture: $(uname -m)"; exit 1 ;;
esac
[[ -d "$CONFIGURATION" ]] || { print -u2 -- "JDTLS configuration was not found: $CONFIGURATION"; exit 1; }

exec "$JAVA_EXECUTABLE" \
    "${JVM_ARGUMENTS[@]}" \
    -Declipse.application=org.eclipse.jdt.ls.core.id1 \
    -Declipse.product=org.eclipse.jdt.ls.core.product \
    -Dosgi.bundles.defaultStartLevel=4 \
    -Dlog.protocol=true \
    -Dlog.level=ALL \
    -jar "$LAUNCHER_JAR" \
    -configuration "$CONFIGURATION" \
    "${SERVER_ARGUMENTS[@]}"
EOF

cat > "$OUTPUT_DIR/bin/jdtls.ps1" <<'EOF'
$ErrorActionPreference = "Stop"

$javaExecutable = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java.exe" } else { "java" }
$lombokAgent = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\lombok\lombok.jar"))
if (-not (Test-Path -LiteralPath $lombokAgent -PathType Leaf)) { throw "JDTLS Lombok agent was not found: $lombokAgent" }
$jvmArguments = [System.Collections.Generic.List[string]]::new()
$jvmArguments.Add("-javaagent:$lombokAgent")
$jvmArguments.Add("--add-modules=ALL-SYSTEM")
$jvmArguments.Add("--add-opens=java.base/java.util=ALL-UNNAMED")
$jvmArguments.Add("--add-opens=java.base/java.lang=ALL-UNNAMED")
$serverArguments = [System.Collections.Generic.List[string]]::new()

for ($index = 0; $index -lt $args.Count; $index++) {
    $argument = [string]$args[$index]
    if ($argument -eq "--java-executable") {
        if ($index + 1 -ge $args.Count) { throw "--java-executable requires a path" }
        $javaExecutable = [string]$args[++$index]
    } elseif ($argument.StartsWith("--jvm-arg=")) {
        $jvmArguments.Add($argument.Substring("--jvm-arg=".Length))
    } elseif ($argument -eq "--jvm-arg") {
        if ($index + 1 -ge $args.Count) { throw "--jvm-arg requires a value" }
        $jvmArguments.Add([string]$args[++$index])
    } else {
        $serverArguments.Add($argument)
    }
}

$launcherJar = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "..\plugins") -Filter "org.eclipse.equinox.launcher_*.jar" |
    Sort-Object Name |
    Select-Object -First 1
if ($null -eq $launcherJar) { throw "JDTLS Equinox launcher was not found" }
$configuration = Join-Path $PSScriptRoot "..\config_win"

& $javaExecutable @jvmArguments `
    "-Declipse.application=org.eclipse.jdt.ls.core.id1" `
    "-Declipse.product=org.eclipse.jdt.ls.core.product" `
    "-Dosgi.bundles.defaultStartLevel=4" `
    "-Dlog.protocol=true" `
    "-Dlog.level=ALL" `
    "-jar" $launcherJar.FullName `
    "-configuration" $configuration `
    @serverArguments
exit $LASTEXITCODE
EOF

cat > "$OUTPUT_DIR/bin/jdtls.bat" <<'EOF'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0jdtls.ps1" %*
exit /b %ERRORLEVEL%
EOF

chmod +x "$OUTPUT_DIR/bin/jdtls"
validate_output
print -r -- "$OUTPUT_DIR"
