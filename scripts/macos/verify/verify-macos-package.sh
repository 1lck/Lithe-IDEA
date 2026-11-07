#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h:h}"
cd "$ROOT_DIR"
if [[ $# -gt 0 ]]; then
    print -u2 -- "Usage: $0"
    exit 2
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/lithe-package-verification.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
dist_root="$temporary_directory/dist"
package_log="$temporary_directory/package.log"
dmg_log="$temporary_directory/dmg.log"
marketplace_index="$ROOT_DIR/Plugins/marketplace/index.json"

env -u LITHE_ARCH \
    LITHE_OFFICIAL_PLUGIN_INDEX="$marketplace_index" \
    LITHE_DIST_ROOT="$dist_root" \
    LITHE_CODESIGN_IDENTITY="-" \
    scripts/macos/package/package-app.sh | tee "$package_log"

app_path="$(tail -n 1 "$package_log")"
expected_app_path="$dist_root/Lithe.app"
if [[ "$app_path" != "$expected_app_path" ]]; then
    print -u2 -- "Unexpected packaged app path: $app_path"
    exit 1
fi

required_executables=(
    "$app_path/Contents/MacOS/Lithe"
    "$app_path/Contents/Frameworks/Sparkle.framework/Sparkle"
    "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
    "$app_path/Contents/Helpers/lithe-mcp"
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
    "$app_path/Contents/Resources/Fonts/Inter-Black.otf"
    "$app_path/Contents/Resources/Fonts/Inter-BlackItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-Bold.otf"
    "$app_path/Contents/Resources/Fonts/Inter-BoldItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-ExtraBold.otf"
    "$app_path/Contents/Resources/Fonts/Inter-ExtraBoldItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-ExtraLight.otf"
    "$app_path/Contents/Resources/Fonts/Inter-ExtraLightItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-Italic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-Light.otf"
    "$app_path/Contents/Resources/Fonts/Inter-LightItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-Medium.otf"
    "$app_path/Contents/Resources/Fonts/Inter-MediumItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-Regular.otf"
    "$app_path/Contents/Resources/Fonts/Inter-SemiBold.otf"
    "$app_path/Contents/Resources/Fonts/Inter-SemiBoldItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-Thin.otf"
    "$app_path/Contents/Resources/Fonts/Inter-ThinItalic.otf"
    "$app_path/Contents/Resources/Fonts/Inter-LICENSE.txt"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-Bold.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-BoldItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-ExtraBold.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-ExtraBoldItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-ExtraLight.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-ExtraLightItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-Italic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-Light.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-LightItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-Medium.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-MediumItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-Regular.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-SemiBold.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-SemiBoldItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-Thin.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMono-ThinItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMonoNerdFontMono-Regular.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMonoNerdFontMono-Bold.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMonoNerdFontMono-Italic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMonoNerdFontMono-BoldItalic.ttf"
    "$app_path/Contents/Resources/Fonts/JetBrainsMonoNerdFont-OFL.txt"
    "$app_path/Contents/Resources/Fonts/OFL.txt"
    "$app_path/Contents/Resources/Fonts/AUTHORS.txt"
    "$app_path/Contents/Resources/Fonts/NOTICE.txt"
    "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
    "$app_path/Contents/Resources/MonacoEditor/index.html"
    "$app_path/Contents/Resources/MonacoEditor/workbench.js"
    "$app_path/Contents/Resources/MonacoEditor/workbench.css"
    "$app_path/Contents/Resources/MonacoEditor/worker.js"
    "$app_path/Contents/Resources/MonacoEditor/textmate-worker.js"
    "$app_path/Contents/Resources/MonacoEditor/onig.wasm"
    "$app_path/Contents/Resources/MonacoEditor/java.tmLanguage.json"
    "$app_path/Contents/Resources/MonacoEditor/makefile.tmLanguage.json"
    "$app_path/Contents/Resources/MonacoEditor/cmake.tmLanguage.json"
    "$app_path/Contents/Resources/MonacoEditor/groovy.tmLanguage.json"
    "$app_path/Contents/Resources/MonacoEditor/CMAKE-LICENSE.txt"
    "$app_path/Contents/Resources/MonacoEditor/MAKE-LICENSE.txt"
    "$app_path/Contents/Resources/MonacoEditor/MONACO-LICENSE.txt"
    "$app_path/Contents/Resources/MonacoEditor/TEXTMATE-LICENSE.md"
    "$app_path/Contents/Resources/MonacoEditor/ONIGURUMA-LICENSE.txt"
    "$app_path/Contents/Resources/MonacoEditor/VSCODE-LICENSE.txt"
    "$app_path/Contents/Resources/MonacoEditor/TEXTMATE-NOTICE.txt"
)
for resource in "${required_resources[@]}"; do
    if [[ ! -e "$resource" ]]; then
        print -u2 -- "Packaged resource is missing: $resource"
        exit 1
    fi
done
/usr/bin/lipo "$app_path/Contents/MacOS/Lithe" -verify_arch arm64 x86_64
/usr/bin/lipo "$app_path/Contents/Frameworks/Sparkle.framework/Sparkle" -verify_arch arm64 x86_64
/usr/bin/otool -l "$app_path/Contents/MacOS/Lithe" | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null
# Java, Go and PHP support are community plugins installed from Lithe Store.
# The app carries no official plugin package, language server or JDK.
if [[ -e "$app_path/Contents/Resources/OfficialPlugins" ]]; then
    print -u2 -- "Packaged app must not contain official plugin packages"
    exit 1
fi
if [[ -e "$app_path/Contents/Resources/LanguageServers" ]]; then
    print -u2 -- "Packaged app must not contain language servers"
    exit 1
fi
if find "$app_path/Contents" -type f \( -name 'org.eclipse.jdt.ls.core_*.jar' -o -name 'libjvm.dylib' \) | /usr/bin/grep -q .; then
    print -u2 -- "Packaged app must not contain JDT LS or a JDK"
    exit 1
fi

if ! cmp -s "$app_path/Contents/Resources/PluginMarketplace/index.json" "$marketplace_index"; then
    print -u2 -- "Packaged app must contain the official plugin marketplace index"
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$app_path"

env -u LITHE_ARCH \
    LITHE_DIST_ROOT="$dist_root" \
    LITHE_VERSION="ci-smoke" \
    scripts/macos/package/create-dmg.sh | tee "$dmg_log"
dmg_path="$(tail -n 1 "$dmg_log")"
expected_dmg_path="$dist_root/Lithe-ci-smoke.dmg"
if [[ "$dmg_path" != "$expected_dmg_path" || ! -s "$dmg_path" ]]; then
    print -u2 -- "Disk image was not created at the expected path: $dmg_path"
    exit 1
fi
hdiutil imageinfo "$dmg_path" > /dev/null

print -- "macOS package and disk image verification passed for the universal architecture"
