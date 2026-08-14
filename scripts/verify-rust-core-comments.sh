#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SOURCE_DIR="$ROOT_DIR/rust/lithe-core/src"
cd "$ROOT_DIR"

rust_files=()
production_files=()
while IFS= read -r -d '' file; do
    rust_files+=("$file")
done < <(find "$SOURCE_DIR" -type f -name '*.rs' -print0)
while IFS= read -r -d '' file; do
    production_files+=("$file")
done < <(find "$SOURCE_DIR" -type f -name '*.rs' \
    ! -path '*/tests/*' \
    ! -name 'tests.rs' \
    -print0)

if (( ${#production_files[@]} == 0 )); then
    print -u2 -- "Rust Core comment verification found no production modules"
    exit 1
fi

failures=0

# Module documentation is a cheap textual check and should fail before Rustdoc runs.
for file in "${production_files[@]}"; do
    first_source_line="$(awk 'NF { sub(/^[[:space:]]*/, ""); print; exit }' "$file")"
    if [[ "$first_source_line" != "//!"* ]]; then
        print -u2 -- "${file#$ROOT_DIR/}:1: production modules must start with //! documentation"
        failures=$((failures + 1))
    fi
done

# Rust Core comments are English. Limit this check to comment-only lines so that
# localized strings and fixtures remain valid source content.
if command -v rg >/dev/null 2>&1; then
    non_english_comments="$(rg -n '^\s*//[/!]?.*\p{Han}' "${rust_files[@]}" || true)"
else
    non_english_comments="$(grep -nE '^[[:space:]]*//.*[一-龥]' "${rust_files[@]}" || true)"
fi
if [[ -n "$non_english_comments" ]]; then
    print -u2 -- "Rust Core comments must be written in English:"
    print -u2 -- "$non_english_comments"
    failures=$((failures + 1))
fi

# The C ABI lives behind a private Rust module, so rustdoc's missing_docs lint
# cannot enforce its safety sections. Check public unsafe functions explicitly.
unsafe_without_safety="$(awk '
    function reset_docs() {
        documented = 0
        safety = 0
    }

    /^[[:space:]]*\/\/\// {
        documented = 1
        if ($0 ~ /#[[:space:]]*Safety/) {
            safety = 1
        }
        next
    }

    /^[[:space:]]*#\[/ {
        in_attribute = ($0 !~ /\][[:space:]]*$/)
        next
    }

    in_attribute {
        if ($0 ~ /\][[:space:]]*$/) {
            in_attribute = 0
        }
        next
    }

    /^[[:space:]]*$/ {
        reset_docs()
        next
    }

    {
        public_unsafe_function = $0 ~ /^[[:space:]]*pub[[:space:]]+(async[[:space:]]+)?(const[[:space:]]+)?unsafe[[:space:]]+(extern[[:space:]]+"[^"]+"[[:space:]]+)?fn[[:space:]]+/
        if (public_unsafe_function && (!documented || !safety)) {
            print FILENAME ":" FNR ": public unsafe functions require /// documentation with a # Safety section"
        }
        reset_docs()
    }
' "${rust_files[@]}")"
if [[ -n "$unsafe_without_safety" ]]; then
    print -u2 -- "$unsafe_without_safety"
    failures=$((failures + 1))
fi

if (( failures > 0 )); then
    exit 1
fi

# Let Rust understand visibility instead of treating pub items in private
# modules as exported APIs. This covers public functions, types, variants, and
# fields without requiring documentation for every internal helper.
cargo rustdoc --quiet \
    --manifest-path rust/lithe-core/Cargo.toml \
    --lib -- \
    -D missing_docs \
    -D rustdoc::broken_intra_doc_links

print "Rust Core comment verification passed"
