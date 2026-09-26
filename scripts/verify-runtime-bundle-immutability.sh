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

# JDT LS is the one runtime that writes into a packaged directory by design.
# Rust Core redirects its Equinox configuration area into the host cache for
# both products; `jdt_configuration` tests and the real JDT LS smoke test
# prove the installation stays byte-identical, so no source pattern is
# duplicated here.

print -- "Runtime bundle immutability verification passed"
