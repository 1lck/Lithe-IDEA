#!/usr/bin/env bash
# Builds the pinned Lithe-core-rust static library for the Viva desktop client and stages the
# header, archive, native linker flags and build identity under .artifacts/desktop/lithe-core/:
#
# Usage: scripts/desktop/build-desktop-core.sh [--debug|--release]
#
#   include/lithe_core.h     the C ABI header of that core revision
#   lib/liblithe_core.a      the static library that cgo links
#   bin/lithe-mcp[.exe]      the IDE API stdio helper the desktop client embeds when packaged
#   native-static-libs.txt   the system libraries and frameworks rustc says the archive needs
#   identity.txt             core revision, dirty flag, rustc, target and profile of the build
#
# LITHE_CORE_RUST_DIR points the build at a local core checkout. LITHE_CORE_TARGET selects a Rust
# target; Windows uses x86_64-pc-windows-gnu because cgo cannot link an MSVC .lib archive. The
# staging directory is build state of this worktree and is never written into an app bundle.
#
# The staging directory is the only line written to standard output, so a caller can read it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

PINNED_CORE_REPOSITORY="https://github.com/Lithe-IDEA/Lithe-core-rust.git"
# Lithe-core-rust #21 (debug.setBreakpointsMuted, debug.planMemoryWindow and
# debug.locateMemoryWindow, runConfig.decideTitleAction), squash-merged into main, on top of #20
# (lsp.declarationOrUsages and the references operation's includeDeclaration, for Go to
# Declaration or Usages), #19 (MCP configuration and library commands removed) and #17: the plugin contract is one
# baseline with pluginAPIVersion and every capability, protocol and document version at 0, and
# the contract, plugin guides, reference and SDKs live only in shared/plugins; on top of #16 (reported Git queries folded in the console),
# #15 (git.write cherryPick, revert and reset fields), #14 (word-level changed ranges of diff
# rows), #13 (execution.planLaunchCommand), #8, #7, #6 and #4.
PINNED_CORE_REVISION="c001967afac3fd8b706c16119c180807cac7d85a"
PROFILE="debug"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) PROFILE="release"; shift ;;
        --debug) PROFILE="debug"; shift ;;
        *) printf '%s\n' "Usage: $0 [--debug|--release]" >&2; exit 2 ;;
    esac
done

HOST_TARGET="$(rustc -vV | sed -n 's/^host: //p')"
RUST_TARGET="${LITHE_CORE_TARGET:-$HOST_TARGET}"
if [[ "$RUST_TARGET" == *-windows-msvc ]]; then
    printf '%s\n' "cgo cannot link the MSVC .lib archive for $RUST_TARGET; use x86_64-pc-windows-gnu for Windows." >&2
    exit 2
fi

ARTIFACTS_DIR="$ROOT_DIR/.artifacts/desktop"
STAGE_DIR="$ARTIFACTS_DIR/lithe-core/$RUST_TARGET/$PROFILE"
CARGO_TARGET_DIR_BASH="$ARTIFACTS_DIR/lithe-core-rust/target"
CARGO_TARGET_DIR_NATIVE="$(native_path "$CARGO_TARGET_DIR_BASH")"
export CARGO_TARGET_DIR="$CARGO_TARGET_DIR_NATIVE"
if [[ "$RUST_TARGET" == *-apple-darwin ]]; then
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
else
    unset MACOSX_DEPLOYMENT_TARGET
fi
# The release profile of Lithe-core-rust sets strip = true. On macOS that also strips the
# proc-macro dylibs cargo builds for the host, and rustc then reports "can't find crate" for
# tokio_macros and futures_macro. Build scripts and proc macros are never shipped, so they are
# left unstripped; the static library is still built with the profile as the core defines it.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP:-false}"

if [[ -n "${LITHE_CORE_RUST_DIR:-}" ]]; then
    CORE_DIR="$(cd "$LITHE_CORE_RUST_DIR" && pwd -P)"
    CORE_SOURCE="override"
else
    CORE_SOURCE="pinned"
    CORE_DIR="$ARTIFACTS_DIR/lithe-core-rust/source"
    if [[ ! -d "$CORE_DIR/.git" ]]; then
        mkdir -p "$(dirname "$CORE_DIR")"
        git clone --filter=blob:none --no-checkout "$PINNED_CORE_REPOSITORY" "$CORE_DIR" >&2
    fi
    if [[ "$(git -C "$CORE_DIR" rev-parse HEAD 2>/dev/null || true)" != "$PINNED_CORE_REVISION" ]]; then
        git -C "$CORE_DIR" fetch --filter=blob:none origin "$PINNED_CORE_REVISION" >&2
        git -C "$CORE_DIR" checkout --detach --force "$PINNED_CORE_REVISION" >&2
    elif [[ ! -e "$CORE_DIR/.git/index" ]]; then
        # A fresh --no-checkout clone can already point at the pin without
        # having any worktree files. Do not force: untracked user files must
        # prevent checkout rather than being overwritten.
        git -C "$CORE_DIR" checkout --detach "$PINNED_CORE_REVISION" >&2
    fi
fi

MANIFEST="$CORE_DIR/rust/Cargo.toml"
if [[ ! -f "$MANIFEST" ]]; then
    printf '%s\n' "No Lithe-core-rust workspace at $CORE_DIR (expected rust/Cargo.toml)." >&2
    exit 1
fi
MANIFEST_NATIVE="$(native_path "$MANIFEST")"

CORE_REVISION="$(git -C "$CORE_DIR" rev-parse HEAD)"
CORE_DIRTY="clean"
if [[ -n "$(git -C "$CORE_DIR" status --porcelain --untracked-files=normal -- rust)" ]]; then
    CORE_DIRTY="dirty"
fi
# rustc prints native libraries only when it links the archive. The file survives up-to-date
# builds, so a missing one triggers a clean that makes rustc report it again.
mkdir -p "$STAGE_DIR/include" "$STAGE_DIR/lib"
NATIVE_LIBS_FILE="$STAGE_DIR/native-static-libs.txt"
NATIVE_LIBS_FILE_NATIVE="$(native_path "$NATIVE_LIBS_FILE")"
PROFILE_ARGS=()
if [[ "$PROFILE" == "release" ]]; then
    PROFILE_ARGS=(--release)
fi
# Cargo puts an explicit target below target/<triple>/ and keeps host builds in target/<profile>/.
LIBRARY_DIR="$CARGO_TARGET_DIR_BASH/$PROFILE"
if [[ "$RUST_TARGET" != "$HOST_TARGET" ]]; then
    PROFILE_ARGS+=(--target "$RUST_TARGET")
    LIBRARY_DIR="$CARGO_TARGET_DIR_BASH/$RUST_TARGET/$PROFILE"
fi
if [[ ! -s "$NATIVE_LIBS_FILE" ]]; then
    cargo clean --manifest-path "$MANIFEST_NATIVE" -p lithe-core \
        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" >&2
fi
cargo rustc --manifest-path "$MANIFEST_NATIVE" -p lithe-core --lib --crate-type staticlib \
    "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" \
    -- --print "native-static-libs=$NATIVE_LIBS_FILE_NATIVE" >&2
if [[ ! -s "$NATIVE_LIBS_FILE" ]]; then
    printf '%s\n' "rustc did not report the native libraries of liblithe_core.a." >&2
    exit 1
fi

install -m 0644 "$LIBRARY_DIR/liblithe_core.a" "$STAGE_DIR/lib/liblithe_core.a"
install -m 0644 "$CORE_DIR/rust/lithe-core/include/lithe_core.h" "$STAGE_DIR/include/lithe_core.h"

# The IDE API helper is the lithe-ide-host crate's lithe-mcp binary from the same pinned
# checkout. It is staged here so packaging can embed it; nothing at runtime reads this
# directory, and the installed client runs only the copy it installs under application data.
HELPER_EXE=""
if [[ "$RUST_TARGET" == *windows* ]]; then
    HELPER_EXE=".exe"
fi
mkdir -p "$STAGE_DIR/bin"
cargo build --manifest-path "$MANIFEST_NATIVE" -p lithe-ide-host --bin lithe-mcp --features mcp \
    "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" >&2
HELPER="$LIBRARY_DIR/lithe-mcp$HELPER_EXE"
if [[ ! -f "$HELPER" ]]; then
    printf '%s\n' "cargo did not build the lithe-mcp helper at $HELPER." >&2
    exit 1
fi
install -m 0755 "$HELPER" "$STAGE_DIR/bin/lithe-mcp$HELPER_EXE"
{
    printf 'core-revision=%s\n' "$CORE_REVISION"
    printf 'core-worktree=%s\n' "$CORE_DIRTY"
    printf 'core-source=%s\n' "$CORE_SOURCE"
    printf 'rustc=%s\n' "$(rustc -V)"
    printf 'target=%s\n' "$RUST_TARGET"
    printf 'profile=%s\n' "$PROFILE"
    if [[ "$RUST_TARGET" == *-apple-darwin ]]; then
        printf 'macos-deployment-target=%s\n' "$MACOSX_DEPLOYMENT_TARGET"
    fi
} > "$STAGE_DIR/identity.txt"
printf '%s\n' "$STAGE_DIR"
