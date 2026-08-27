#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/lithe-package-verification.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
jdtls_root="$temporary_directory/jdtls"
arm64_jdk_root="$temporary_directory/jdk-arm64"
x86_64_jdk_root="$temporary_directory/jdk-x86_64"
dist_root="$temporary_directory/dist"
package_log="$temporary_directory/package.log"
dmg_log="$temporary_directory/dmg.log"

# The package smoke test validates assembly rather than third-party downloads.
# This fixture satisfies prepare-jdtls.sh's production layout checks while
# keeping CI deterministic and independent of the Eclipse download service.
mkdir -p \
    "$jdtls_root/plugins" \
    "$jdtls_root/config_mac_arm" \
    "$jdtls_root/config_mac" \
    "$jdtls_root/config_win" \
    "$jdtls_root/bin" \
    "$jdtls_root/lombok"
cat > "$jdtls_root/bin/jdtls" <<'LAUNCHER'
#!/bin/zsh
java_agent_argument="-javaagent:../lombok/lombok.jar"
print -r -- "$java_agent_argument"
LAUNCHER
chmod +x "$jdtls_root/bin/jdtls"
cat > "$jdtls_root/bin/jdtls.ps1" <<'LAUNCHER'
$javaAgentArgument = "-javaagent:../lombok/lombok.jar"
Write-Output $javaAgentArgument
LAUNCHER
: > "$jdtls_root/lombok/lombok.jar"
: > "$jdtls_root/lombok/LICENSE-MIT.txt"
: > "$jdtls_root/plugins/org.eclipse.equinox.launcher_1.0.0.jar"

for missing_configuration in config_mac_arm config_mac; do
    broken_jdtls_root="$temporary_directory/jdtls-missing-$missing_configuration"
    cp -R "$jdtls_root" "$broken_jdtls_root"
    rm -rf -- "$broken_jdtls_root/$missing_configuration"
    failure_log="$temporary_directory/missing-$missing_configuration.log"
    if env -u LITHE_ARCH \
        LITHE_JDTLS_ROOT="$broken_jdtls_root" \
        LITHE_JDK_ROOT="$temporary_directory/invalid-jdk" \
        scripts/package-app.sh > "$failure_log" 2>&1; then
        print -u2 -- "Default universal packaging accepted JDTLS without $missing_configuration"
        exit 1
    fi
    if ! grep -Fq "JDTLS $missing_configuration configuration is missing" "$failure_log"; then
        print -u2 -- "Default universal packaging did not validate $missing_configuration before building"
        cat "$failure_log" >&2
        exit 1
    fi
done

cat > "$temporary_directory/java.c" <<'SOURCE'
int main(void) { return 0; }
SOURCE
for jdk_arch in arm64 x86_64; do
    jdk_root="$temporary_directory/jdk-$jdk_arch"
    mkdir -p "$jdk_root/bin" "$jdk_root/lib"
    xcrun clang -arch "$jdk_arch" "$temporary_directory/java.c" -o "$jdk_root/bin/java"
    cat > "$jdk_root/release" <<'RELEASE'
JAVA_VERSION="21.0.0"
RELEASE
done

env -u LITHE_ARCH -u LITHE_JDK_ROOT \
    LITHE_DIST_ROOT="$dist_root" \
    LITHE_JDTLS_ROOT="$jdtls_root" \
    LITHE_JDK_ARM64_ROOT="$arm64_jdk_root" \
    LITHE_JDK_X86_64_ROOT="$x86_64_jdk_root" \
    LITHE_CODESIGN_IDENTITY="-" \
    scripts/package-app.sh | tee "$package_log"

app_path="$(tail -n 1 "$package_log")"
expected_app_path="$dist_root/Lithe.app"
if [[ "$app_path" != "$expected_app_path" ]]; then
    print -u2 -- "Unexpected packaged app path: $app_path"
    exit 1
fi

required_executables=(
    "$app_path/Contents/MacOS/Lithe"
    "$app_path/Contents/Helpers/lithe-db-sidecar"
    "$app_path/Contents/Helpers/lithe-db-mcp"
)
for executable in "${required_executables[@]}"; do
    if [[ ! -x "$executable" ]]; then
        print -u2 -- "Packaged executable is missing: $executable"
        exit 1
    fi
done

required_resources=(
    "$app_path/Contents/Info.plist"
    "$app_path/Contents/Resources/Lithe_Lithe.bundle"
    "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
    "$app_path/Contents/Resources/LanguageServers/jdtls/bin/jdtls"
    "$app_path/Contents/Resources/LanguageServers/jdtls/plugins/org.eclipse.equinox.launcher_1.0.0.jar"
    "$app_path/Contents/Resources/LanguageServers/jdtls/config_mac_arm"
    "$app_path/Contents/Resources/LanguageServers/jdtls/config_mac"
    "$app_path/Contents/Resources/LanguageServers/jdtls/lombok/lombok.jar"
    "$app_path/Contents/Resources/LanguageServers/jdk-arm64/bin/java"
    "$app_path/Contents/Resources/LanguageServers/jdk-arm64/lib"
    "$app_path/Contents/Resources/LanguageServers/jdk-x86_64/bin/java"
    "$app_path/Contents/Resources/LanguageServers/jdk-x86_64/lib"
)
for resource in "${required_resources[@]}"; do
    if [[ ! -e "$resource" ]]; then
        print -u2 -- "Packaged resource is missing: $resource"
        exit 1
    fi
done
/usr/bin/lipo "$app_path/Contents/MacOS/Lithe" -verify_arch arm64 x86_64
/usr/bin/lipo \
    "$app_path/Contents/Resources/LanguageServers/jdk-arm64/bin/java" \
    -verify_arch arm64
/usr/bin/lipo \
    "$app_path/Contents/Resources/LanguageServers/jdk-x86_64/bin/java" \
    -verify_arch x86_64

plugin_manifests=("$app_path/Contents/Resources/OfficialPlugins"/*/plugin.json(N))
if (( ${#plugin_manifests[@]} == 0 )); then
    print -u2 -- "Packaged app does not contain any official plugin manifests"
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$app_path"

env -u LITHE_ARCH \
    LITHE_DIST_ROOT="$dist_root" \
    LITHE_VERSION="ci-smoke" \
    scripts/create-dmg.sh | tee "$dmg_log"
dmg_path="$(tail -n 1 "$dmg_log")"
expected_dmg_path="$dist_root/Lithe-ci-smoke.dmg"
if [[ "$dmg_path" != "$expected_dmg_path" || ! -s "$dmg_path" ]]; then
    print -u2 -- "Disk image was not created at the expected path: $dmg_path"
    exit 1
fi
hdiutil imageinfo "$dmg_path" > /dev/null

print -- "macOS package and disk image verification passed for the default universal architecture"
