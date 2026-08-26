#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="x86_64" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/lithe-package-verification.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
jdtls_root="$temporary_directory/jdtls"
jdk_root="$temporary_directory/jdk"
dist_root="$temporary_directory/dist"
package_log="$temporary_directory/package.log"
dmg_log="$temporary_directory/dmg.log"

# The package smoke test validates assembly rather than third-party downloads.
# This fixture satisfies prepare-jdtls.sh's production layout checks while
# keeping CI deterministic and independent of the Eclipse download service.
mkdir -p \
    "$jdtls_root/plugins" \
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

mkdir -p "$jdk_root/bin" "$jdk_root/lib"
cat > "$temporary_directory/java.c" <<'SOURCE'
int main(void) { return 0; }
SOURCE
xcrun clang -arch "$ARCH" "$temporary_directory/java.c" -o "$jdk_root/bin/java"
cat > "$jdk_root/release" <<'RELEASE'
JAVA_VERSION="21.0.0"
RELEASE

LITHE_ARCH="$ARCH" \
LITHE_DIST_ROOT="$dist_root" \
LITHE_JDTLS_ROOT="$jdtls_root" \
LITHE_JDK_ROOT="$jdk_root" \
LITHE_CODESIGN_IDENTITY="-" \
    scripts/package-app.sh | tee "$package_log"

app_path="$(tail -n 1 "$package_log")"
expected_app_path="$dist_root/Lithe-$ARCH.app"
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
    "$app_path/Contents/Resources/LanguageServers/jdk/bin/java"
    "$app_path/Contents/Resources/LanguageServers/jdk/lib"
)
for resource in "${required_resources[@]}"; do
    if [[ ! -e "$resource" ]]; then
        print -u2 -- "Packaged resource is missing: $resource"
        exit 1
    fi
done
/usr/bin/lipo \
    "$app_path/Contents/Resources/LanguageServers/jdk/bin/java" \
    -verify_arch "$ARCH"

plugin_manifests=("$app_path/Contents/Resources/OfficialPlugins"/*/plugin.json(N))
if (( ${#plugin_manifests[@]} == 0 )); then
    print -u2 -- "Packaged app does not contain any official plugin manifests"
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$app_path"

LITHE_ARCH="$ARCH" \
LITHE_DIST_ROOT="$dist_root" \
LITHE_VERSION="ci-smoke" \
    scripts/create-dmg.sh | tee "$dmg_log"
dmg_path="$(tail -n 1 "$dmg_log")"
expected_dmg_path="$dist_root/Lithe-ci-smoke-$ARCH.dmg"
if [[ "$dmg_path" != "$expected_dmg_path" || ! -s "$dmg_path" ]]; then
    print -u2 -- "Disk image was not created at the expected path: $dmg_path"
    exit 1
fi
hdiutil imageinfo "$dmg_path" > /dev/null

print -- "macOS package and disk image verification passed for $ARCH"
