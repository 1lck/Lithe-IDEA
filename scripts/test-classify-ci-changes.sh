#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/scripts"
cp "$ROOT_DIR/scripts/classify-ci-changes.sh" "$TEST_ROOT/scripts/"
cd "$TEST_ROOT"

git init -q
git config user.email "ci@example.invalid"
git config user.name "CI Test"
mkdir -p rust/lithe-core/src docs
printf '%s\n' '//! Test module.' 'pub fn value() -> u8 { 1 }' > rust/lithe-core/src/lib.rs
printf '%s\n' '# Test' > README.md
git add .
git commit -q -m base
BASE_REVISION="$(git rev-parse HEAD)"

assert_classification() {
    local name="$1"
    local expected="$2"
    shift 2

    git reset --hard -q "$BASE_REVISION"
    git clean -fdq
    "$@"
    git add .
    git commit -q -m "$name"

    local actual
    actual="$(scripts/classify-ci-changes.sh "$BASE_REVISION" HEAD)"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Classifier case %s failed:\nExpected:\n%s\nActual:\n%s\n' \
            "$name" "$expected" "$actual" >&2
        exit 1
    fi
}

modify_readme() {
    printf '%s\n' '# Updated' > README.md
}

modify_rust_comment() {
    printf '%s\n' '//! Updated test module.' 'pub fn value() -> u8 { 1 }' > rust/lithe-core/src/lib.rs
}

modify_rust_code() {
    printf '%s\n' '//! Test module.' 'pub fn value() -> u8 { 2 }' > rust/lithe-core/src/lib.rs
}

rename_rust_to_markdown() {
    mkdir -p docs
    git mv rust/lithe-core/src/lib.rs docs/lib.md
}

assert_classification \
    readme \
    $'full=false\ncomments=true\nmetadata=false' \
    modify_readme
assert_classification \
    rust-comment \
    $'full=false\ncomments=true\nmetadata=false' \
    modify_rust_comment
assert_classification \
    rust-code \
    $'full=true\ncomments=false\nmetadata=false' \
    modify_rust_code
assert_classification \
    rename-rust-to-markdown \
    $'full=true\ncomments=false\nmetadata=false' \
    rename_rust_to_markdown

printf '%s\n' 'CI change classifier tests passed'
