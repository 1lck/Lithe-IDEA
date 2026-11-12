#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h:h}"
cd "$ROOT_DIR"

# The unified client shares its production sources across macOS and Windows.
# Mutable data uses a platform user-data/cache directory. The installed package
# (app bundle or installation folder) is located in one place only:
# desktop/internal/installedpackage, which documents its read-only ownership;
# fixed resources such as the bundled fonts are compiled into the executable, so
# nothing reads the bundle for them. Fail closed if any other file derives a path
# from the executable or the bundle, or if that package ever writes to the file
# system.
if [[ ! -d desktop/internal || ! -d desktop/cmd ]]; then
    print -u2 -- "Desktop production sources are missing; cannot verify runtime resource paths."
    exit 1
fi
installed_package_dir=desktop/internal/installedpackage
if [[ ! -d "$installed_package_dir" ]]; then
    print -u2 -- "Missing $installed_package_dir; cannot verify where the installed package is located."
    exit 1
fi
desktop_path_pattern='os[.]Executable\(|os[.]Args\[0\]|GetModuleFileName|Contents/Resources|Bundle[.]main|resource_dir\('
desktop_violations=$(
    { find desktop/internal desktop/cmd -type f -name '*.go' ! -name '*_test.go' \
        ! -path "$installed_package_dir/*" -print0 \
        | xargs -0 /usr/bin/grep -En -- "$desktop_path_pattern"; } 2>&1 || true
)
if [[ -n "$desktop_violations" ]]; then
    print -u2 -- "Desktop runtime must locate its installed package only through $installed_package_dir:"
    print -u2 -- "$desktop_violations"
    exit 1
fi
installed_package_write_pattern='os[.](WriteFile|Create|CreateTemp|OpenFile|Mkdir|MkdirAll|MkdirTemp|Rename|Remove|RemoveAll|Chmod|Chown|Chtimes|Symlink|Link|Truncate)\(|ioutil[.]|os/exec|syscall[.]|golang[.]org/x/sys'
installed_package_writes=$(
    { find "$installed_package_dir" -type f -name '*.go' ! -name '*_test.go' -print0 \
        | xargs -0 /usr/bin/grep -En -- "$installed_package_write_pattern"; } 2>&1 || true
)
if [[ -n "$installed_package_writes" ]]; then
    print -u2 -- "$installed_package_dir must stay read-only:"
    print -u2 -- "$installed_package_writes"
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
