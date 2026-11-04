#!/bin/zsh
set -euo pipefail

# Builds the fixed provider sources for this app's target architectures.
# Cargo outputs are mutable worktree-local build state; the copied executable
# and licenses are sealed into the plugin package before the app is signed.
PLUGIN_DIR="${0:A:h}"
ROOT_DIR="${PLUGIN_DIR:h:h:h:h}"
OUTPUT_DIR=""
ARCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 --output package-directory --arch arm64|x86_64|universal"; exit 2 ;;
    esac
done
[[ -n "$OUTPUT_DIR" ]] || { print -u2 -- "--output is required"; exit 2; }
case "$ARCH" in
    arm64) targets=(aarch64-apple-darwin) ;;
    x86_64) targets=(x86_64-apple-darwin) ;;
    universal) targets=(aarch64-apple-darwin x86_64-apple-darwin) ;;
    *) print -u2 -- "Unsupported architecture: $ARCH"; exit 2 ;;
esac
target_dir="$ROOT_DIR/.artifacts/editor-keymap-provider-target"
binaries=()
for target in "${targets[@]}"; do
    CARGO_HOME="$ROOT_DIR/.artifacts/cargo-home" cargo build --locked --release --manifest-path "$PLUGIN_DIR/Cargo.toml" --target "$target" --target-dir "$target_dir"
    binaries+=("$target_dir/$target/release/lithe-editor-keymap-import")
done
mkdir -p "$OUTPUT_DIR/bin"
if (( ${#binaries} == 1 )); then
    cp "$binaries[1]" "$OUTPUT_DIR/bin/editor-keymap-import"
else
    lipo -create "${binaries[@]}" -output "$OUTPUT_DIR/bin/editor-keymap-import"
fi
chmod 755 "$OUTPUT_DIR/bin/editor-keymap-import"
cp "$PLUGIN_DIR/NOTICE.md" "$OUTPUT_DIR/NOTICE.md"
cp -R "$PLUGIN_DIR/licenses" "$OUTPUT_DIR/licenses"
