#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

# A resource lookup is safe. A write whose destination is derived from that
# lookup changes the installed app and invalidates Sparkle differential bases.
# Keep this scan deliberately narrow so workspace and user-data writes remain
# valid while direct bundle mutations fail loudly during every macOS build.
bundle_write_pattern='(Bundle\.main\.(resourceURL|bundleURL)|Contents/Resources).*(write|createDirectory|copyItem|moveItem|removeItem)|((write|createDirectory|copyItem|moveItem|removeItem).*)(Bundle\.main\.(resourceURL|bundleURL)|Contents/Resources)'
bundle_write_violations=$(
    find macos/Sources -type f -name '*.swift' -print0 \
        | xargs -0 /usr/bin/grep -En -- "$bundle_write_pattern" || true
)
if [[ -n "$bundle_write_violations" ]]; then
    print -u2 -- "Runtime code must not write to a path derived from the macOS app bundle:"
    print -u2 -- "$bundle_write_violations"
    exit 1
fi

resolver='macos/Sources/Lithe/Platform/MacOS/Runtime/MacJDTLSLaunchResourceResolver.swift'
for required in \
    'configurationCacheDirectoryURL' \
    'cacheDirectoryIsOutsideBundle' \
    'isBundled(installationRootURL)' \
    'SHA256' \
    'copyItem(at: bundledConfigurationURL, to: stagingURL)' \
    'moveItem(at: stagingURL, to: cachedConfigurationURL)'; do
    if ! /usr/bin/grep -Fq -- "$required" "$resolver"; then
        print -u2 -- "JDTLS bundle immutability guard is incomplete: missing $required"
        exit 1
    fi
done

container='macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift'
if ! /usr/bin/grep -Fq -- 'configurationCacheDirectoryURL: languageServerCacheDirectory' "$container"; then
    print -u2 -- "MacServiceContainer must route JDTLS mutable configuration into the cache"
    exit 1
fi

windows_lsp='windows/tauri/src-tauri/src/lsp.rs'
windows_cache_body=$(
    sed -n '/fn language_server_cache_directory/,/^}/p' "$windows_lsp"
)
if [[ "$windows_cache_body" != *'app_cache_dir()'* ]]; then
    print -u2 -- "Windows language-server state must use Tauri app_cache_dir()"
    exit 1
fi
if [[ "$windows_cache_body" == *'resource_dir()'* ]]; then
    print -u2 -- "Windows language-server cache must not use resource_dir()"
    exit 1
fi

print -- "Runtime bundle immutability verification passed"
