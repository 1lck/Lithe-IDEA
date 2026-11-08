#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h:h}"
cd "$ROOT_DIR"

# The unified client shares its production sources across macOS and Windows.
# No current runtime resource needs to locate the executable: bundled assets
# are embedded and mutable data uses a platform user-data/cache directory.
# Fail closed if a future change introduces executable-derived paths; it must
# add explicit ownership and runtime bundle-hash validation before use.
if [[ ! -d desktop/internal || ! -d desktop/cmd ]]; then
    print -u2 -- "Desktop production sources are missing; cannot verify runtime resource paths."
    exit 1
fi
desktop_path_pattern='os[.]Executable\(|os[.]Args\[0\]|GetModuleFileName|Contents/Resources|Bundle[.]main|resource_dir\('
desktop_violations=$(
    { find desktop/internal desktop/cmd -type f -name '*.go' ! -name '*_test.go' -print0 \
        | xargs -0 /usr/bin/grep -En -- "$desktop_path_pattern"; } 2>&1 || true
)
if [[ -n "$desktop_violations" ]]; then
    print -u2 -- "Desktop runtime must not derive writable resources from its installed package:"
    print -u2 -- "$desktop_violations"
    exit 1
fi

# Retain the legacy checks when those clients are present, so a checkout that
# contains both architectures cannot silently stop checking their paths.
bundle_write_pattern='(Bundle\.main\.(resourceURL|bundleURL)|Contents/Resources).*(write|createDirectory|copyItem|moveItem|removeItem)|((write|createDirectory|copyItem|moveItem|removeItem).*)(Bundle\.main\.(resourceURL|bundleURL)|Contents/Resources)'
if [[ -d macos/Sources ]]; then
    bundle_write_violations=$(
        { find macos/Sources -type f -name '*.swift' -print0 \
            | xargs -0 /usr/bin/grep -En -- "$bundle_write_pattern"; } 2>&1 || true
    )
    if [[ -n "$bundle_write_violations" ]]; then
        print -u2 -- "Runtime code must not write to a path derived from the macOS app bundle:"
        print -u2 -- "$bundle_write_violations"
        exit 1
    fi
fi

windows_bundle_write_pattern='(resource_dir\(\)|resolve_resource\().*(write|create_dir|copy|rename|remove_file)|((write|create_dir|copy|rename|remove_file).*)(resource_dir\(\)|resolve_resource\()'
if [[ -d windows/tauri/src-tauri/src ]]; then
    windows_bundle_write_violations=$(
        { find windows/tauri/src-tauri/src -type f -name '*.rs' -print0 \
            | xargs -0 /usr/bin/grep -En -- "$windows_bundle_write_pattern"; } 2>&1 || true
    )
    if [[ -n "$windows_bundle_write_violations" ]]; then
        print -u2 -- "Runtime code must not write to Windows packaged resources:"
        print -u2 -- "$windows_bundle_write_violations"
        exit 1
    fi
fi

print -- "Runtime bundle immutability static checks passed (desktop macOS and Windows sources)."
