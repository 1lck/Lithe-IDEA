#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
    printf 'Usage: %s <base-revision> <head-revision>\n' "$0" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BASE_REVISION="$1"
HEAD_REVISION="$2"
cd "$ROOT_DIR"

git cat-file -e "${BASE_REVISION}^{commit}"
git cat-file -e "${HEAD_REVISION}^{commit}"

rust_diff_is_comment_only() {
    local path="$1"
    local in_hunk=false
    local saw_change=false
    local line content

    while IFS= read -r line; do
        if [[ "$line" == @@* ]]; then
            in_hunk=true
            continue
        fi
        if [[ "$in_hunk" == true && ( "$line" == +* || "$line" == -* ) ]]; then
            saw_change=true
            content="${line:1}"
            if [[ ! "$content" =~ ^[[:space:]]*(//.*)?$ ]]; then
                return 1
            fi
        fi
    done < <(git diff --no-color --unified=0 "$BASE_REVISION" "$HEAD_REVISION" -- "$path")

    [[ "$saw_change" == true ]]
}

full=false
comments=false
metadata=false

while IFS=$'\t' read -r status first_path _; do
    if [[ "$status" == R* || "$status" == C* ]]; then
        # A rename or copy can move executable content into a lightweight path.
        # Keep the classifier fail-closed because both paths affect behavior.
        full=true
        break
    fi

    path="$first_path"
    lowercase_path="${path,,}"

    case "$lowercase_path" in
        *.md|*.mdx)
            comments=true
            ;;
        casks/*)
            metadata=true
            ;;
        rust/lithe-core/src/*.rs)
            # Added, deleted, copied, and renamed modules can affect compilation
            # even when their visible contents happen to be comments only.
            if [[ "$status" == M* ]] && rust_diff_is_comment_only "$path"; then
                comments=true
            else
                full=true
                break
            fi
            ;;
        *)
            full=true
            break
            ;;
    esac
done < <(git diff --name-status --find-renames "$BASE_REVISION" "$HEAD_REVISION")

printf 'full=%s\n' "$full"
printf 'comments=%s\n' "$comments"
printf 'metadata=%s\n' "$metadata"
