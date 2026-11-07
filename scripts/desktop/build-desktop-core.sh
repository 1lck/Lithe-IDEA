#!/bin/zsh
# Builds the Lithe-core-rust static library that the Viva desktop client (desktop/) links, and
# stages exactly what cgo needs under .artifacts/desktop/lithe-core/<profile>/:
#
#   include/lithe_core.h     the C ABI header of that core revision
#   lib/liblithe_core.a      the static library only, so the linker never picks a dylib
#   native-static-libs.txt   the system libraries and frameworks rustc says the archive needs
#   identity.txt             core revision, dirty flag, rustc, target and profile of the build
#
# The core is the pinned Lithe-core-rust revision below, checked out into
# .artifacts/desktop/lithe-core-rust/source. LITHE_CORE_RUST_DIR points the build at a local
# checkout instead (for a core change that has not been merged yet). Everything written here is
# build state of this worktree: nothing is shared between worktrees and nothing reaches an app
# bundle at runtime.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
PINNED_CORE_REPOSITORY="https://github.com/Lithe-IDEA/Lithe-core-rust.git"
# The head of Lithe-IDEA/Lithe-core-rust#1 (workbench.chromeLayout.reduce), which is not merged
# into main yet; move the pin to the merge commit once it is.
PINNED_CORE_REVISION="7e6d83651ba9fc944c1e5505596eac83ac75f2bd"
PROFILE="debug"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) PROFILE="release"; shift ;;
        --debug) PROFILE="debug"; shift ;;
        *) print -u2 -- "Usage: $0 [--debug|--release]"; exit 2 ;;
    esac
done

ARTIFACTS_DIR="$ROOT_DIR/.artifacts/desktop"
STAGE_DIR="$ARTIFACTS_DIR/lithe-core/$PROFILE"
export CARGO_TARGET_DIR="$ARTIFACTS_DIR/lithe-core-rust/target"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

if [[ -n "${LITHE_CORE_RUST_DIR:-}" ]]; then
    CORE_DIR="${LITHE_CORE_RUST_DIR:A}"
    CORE_SOURCE="override"
else
    CORE_SOURCE="pinned"
    CORE_DIR="$ARTIFACTS_DIR/lithe-core-rust/source"
    if [[ ! -d "$CORE_DIR/.git" ]]; then
        mkdir -p "${CORE_DIR:h}"
        git clone --filter=blob:none --no-checkout "$PINNED_CORE_REPOSITORY" "$CORE_DIR"
    fi
    if [[ "$(git -C "$CORE_DIR" rev-parse HEAD 2>/dev/null || true)" != "$PINNED_CORE_REVISION" ]]; then
        git -C "$CORE_DIR" fetch --filter=blob:none origin "$PINNED_CORE_REVISION"
        git -C "$CORE_DIR" checkout --detach --force "$PINNED_CORE_REVISION"
    fi
fi
MANIFEST="$CORE_DIR/rust/Cargo.toml"
if [[ ! -f "$MANIFEST" ]]; then
    print -u2 -- "No Lithe-core-rust workspace at $CORE_DIR (expected rust/Cargo.toml)."
    exit 1
fi

CORE_REVISION="$(git -C "$CORE_DIR" rev-parse HEAD)"
CORE_DIRTY="clean"
if [[ -n "$(git -C "$CORE_DIR" status --porcelain --untracked-files=normal -- rust)" ]]; then
    CORE_DIRTY="dirty"
fi
RUST_TARGET="$(rustc -vV | sed -n 's/^host: //p')"

# rustc prints the native libraries only when it links the archive. The list is written to a
# file that survives up-to-date builds; when it is missing the crate is cleaned so rustc runs.
mkdir -p "$STAGE_DIR/include" "$STAGE_DIR/lib"
NATIVE_LIBS_FILE="$STAGE_DIR/native-static-libs.txt"
PROFILE_ARGS=()
if [[ "$PROFILE" == "release" ]]; then
    PROFILE_ARGS=(--release)
fi
if [[ ! -s "$NATIVE_LIBS_FILE" ]]; then
    cargo clean --manifest-path "$MANIFEST" -p lithe-core "${PROFILE_ARGS[@]}"
fi
cargo rustc --manifest-path "$MANIFEST" -p lithe-core --lib --crate-type staticlib "${PROFILE_ARGS[@]}" \
    -- --print "native-static-libs=$NATIVE_LIBS_FILE"
if [[ ! -s "$NATIVE_LIBS_FILE" ]]; then
    print -u2 -- "rustc did not report the native libraries of liblithe_core.a."
    exit 1
fi

install -m 0644 "$CARGO_TARGET_DIR/$PROFILE/liblithe_core.a" "$STAGE_DIR/lib/liblithe_core.a"
install -m 0644 "$CORE_DIR/rust/lithe-core/include/lithe_core.h" "$STAGE_DIR/include/lithe_core.h"
{
    print -r -- "core-revision=$CORE_REVISION"
    print -r -- "core-worktree=$CORE_DIRTY"
    print -r -- "core-source=$CORE_SOURCE"
    print -r -- "rustc=$(rustc -V)"
    print -r -- "target=$RUST_TARGET"
    print -r -- "profile=$PROFILE"
    print -r -- "macos-deployment-target=$MACOSX_DEPLOYMENT_TARGET"
} > "$STAGE_DIR/identity.txt"
print -r -- "$STAGE_DIR"
