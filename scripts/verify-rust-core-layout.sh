#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

unexpected="$(find rust/lithe-core/src -maxdepth 1 -type f -name '*.rs' ! -name 'lib.rs' -print)"
if [[ -n "$unexpected" ]]; then
    print -u2 -- "Rust Core implementation files must live in an owned package:"
    print -u2 -- "$unexpected"
    exit 1
fi

for package in protocol runtime project execution languages git lsp tests; do
    if [[ ! -f "rust/lithe-core/src/$package/mod.rs" ]]; then
        print -u2 -- "Rust Core package is missing its facade: $package"
        exit 1
    fi
done

legacy_pattern='crate::(error|model|command|cancellation|workspace|history|markdown|run_configuration|detectors|java|maven)\b'
if command -v rg >/dev/null 2>&1; then
    legacy_matches="$(rg -n "$legacy_pattern" rust/lithe-core/src -g '*.rs' || true)"
else
    legacy_matches="$(grep -REn "$legacy_pattern" rust/lithe-core/src --include='*.rs' || true)"
fi
if [[ -n "$legacy_matches" ]]; then
    print -u2 -- "Rust Core contains imports that bypass the package layout"
    print -u2 -- "$legacy_matches"
    exit 1
fi

print "Rust Core package layout verification passed"
