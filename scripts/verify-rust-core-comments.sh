#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
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
    printf '%s\n' "Rust Core comment verification found no production modules" >&2
    exit 1
fi

failures=0

# Module documentation is a cheap textual check and should fail before Rustdoc runs.
for file in "${production_files[@]}"; do
    first_source_line="$(awk 'NF { sub(/^[[:space:]]*/, ""); print; exit }' "$file")"
    if [[ "$first_source_line" != "//!"* ]]; then
        relative_file="${file#"$ROOT_DIR"/}"
        printf '%s\n' "$relative_file:1: production modules must start with //! documentation" >&2
        failures=$((failures + 1))
    fi
done

# Rust Core comments are English. Keep URL schemes out of the line-comment
# match, then scan block comments separately so localized strings remain valid
# source content without allowing inline comments to bypass the rule.
if command -v rg >/dev/null 2>&1; then
    non_english_line_comments="$(rg -n '(^|[^:])//.*\p{Han}' "${rust_files[@]}" || true)"
else
    non_english_line_comments="$(grep -nE '(^|[^:])//.*[一-龥]' "${rust_files[@]}" || true)"
fi
non_english_block_comments="$(awk '
    FNR == 1 { in_block = 0 }

    function emit_if_localized(value) {
        if (value ~ /[一-龥]/) {
            print FILENAME ":" FNR ":" value
        }
    }

    {
        remaining = $0
        while (1) {
            if (in_block) {
                end_position = index(remaining, "*/")
                if (end_position == 0) {
                    emit_if_localized(remaining)
                    break
                }
                emit_if_localized(substr(remaining, 1, end_position + 1))
                remaining = substr(remaining, end_position + 2)
                in_block = 0
            } else {
                open = index(remaining, "/*")
                line_comment = index(remaining, "//")
                if (line_comment > 0 && (open == 0 || line_comment < open)) {
                    break
                }
                if (open == 0) {
                    break
                }
                remaining = substr(remaining, open + 2)
                in_block = 1
            }
        }
    }
' "${rust_files[@]}" || true)"
non_english_comments="$(printf '%s\n%s\n' "$non_english_line_comments" "$non_english_block_comments" | sed '/^$/d' | sort -u)"
if [[ -n "$non_english_comments" ]]; then
    printf '%s\n' "Rust Core comments must be written in English:" >&2
    printf '%s\n' "$non_english_comments" >&2
    failures=$((failures + 1))
fi

# The C ABI lives behind a private Rust module, so rustdoc's missing_docs lint
# cannot enforce its safety sections. Check public unsafe functions explicitly.
unsafe_without_safety="$(awk '
    function reset_docs() {
        documented = 0
        safety = 0
    }

    FNR == 1 {
        reset_docs()
        in_attribute = 0
    }

    /^[[:space:]]*\/\/\/([^!]|$)/ {
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
        public_unsafe_function = $0 ~ /^[[:space:]]*pub([[:space:]]*\([^)]*\))?[[:space:]]+(async[[:space:]]+)?(const[[:space:]]+)?unsafe[[:space:]]+(extern[[:space:]]+"[^"]+"[[:space:]]+)?fn[[:space:]]+/
        if (public_unsafe_function && (!documented || !safety)) {
            print FILENAME ":" FNR ": public unsafe functions require /// documentation with a # Safety section"
        }
        reset_docs()
    }
' "${rust_files[@]}")"
if [[ -n "$unsafe_without_safety" ]]; then
    printf '%s\n' "$unsafe_without_safety" >&2
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

printf '%s\n' "Rust Core comment verification passed"
