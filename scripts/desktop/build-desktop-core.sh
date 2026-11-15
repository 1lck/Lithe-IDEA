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
# Lithe-core-rust #53, squash-merged into main as c550c2b: a plugin declares commandInstallers that
# install the commands its systemCommand launches need with an injected tool, and Core expands
# them (plugins.commandInstallers.requirements/plan/defaultDirectory). It is on top of
# Lithe-core-rust #52, squash-merged into main as 6477e9a: a tool definition's version probe may
# lead with a subcommand (go version) followed only by flags. It is on top of #51 (Rust 1.100
# clippy lints fixed and the Rust 1.100.0 toolchain pinned), #50 (Core CI runs the affected crates
# only), #49 (Core panics are logged; the desktop panic and crash events are declared) and #48
# (platform rules are data; platform-specific tests live in lithe-platform-tests), all
# squash-merged into main, on top of
# Lithe-core-rust #47, squash-merged into main as a58e07e:
# debug.adapters.readAnnouncement reads one line of a tcpAnnounced adapter's output against its
# declared endpoint (none, announced with a loopback host and port, or invalid), and an adapter's
# launch arguments may bind target.directory, the selected target's directory. It is on top of
# Lithe-core-rust #46, squash-merged into main: the logging event catalog declares the events the
# desktop records (terminal.session.start_failed, vcs.provider.skipped,
# app.background.operation_failed, app.startup.leftovers_resolved, editor.recovery.applied and the
# drag_drop surface) and drops the 90 events only the macOS client used; a failure of
# diagnostics.encodeLogBatch carries the index of the refused input. It is on top of #45,
# squash-merged into main: processMemory.summarize
# also sums the memory the
# system compressed or swapped out, graphics memory, and the processor and graphics use between
# two tables, which the host sends back as a baseline. It is on top of #44, squash-merged into
# main: outputStyle.decode turns console output with ANSI escapes into plain lines and styled
# ranges, carrying each console's state from chunk to chunk, for the colors of the Run, Build and
# Test consoles. It is on top of #43, squash-merged into main: processMemory.summarize
# sorts the native process table into the parts of a Lithe instance (main process, language
# servers, plugin services, their child processes and the system helpers macOS holds the main
# process responsible for) for the memory details of the status bar. It is on top of #42,
# squash-merged into main: htmlPreview.site names the folder an HTML file is previewed from as a
# static site, and htmlPreview.resolveRequest decides what each request of the preview serves. It
# is on top of #41, squash-merged into main: markdown.outline outlines the headings of Markdown
# source as a document-symbol tree for the Structure tool window. It is on top of #40,
# squash-merged into main: the update.delta.cleanup_failed event, which the
# desktop logs when it cannot remove the application a delta update rebuilt in the temporary
# directory. It is on top of #39, squash-merged into main: plugins.installed.lifecycle keeps one
# enabled plugin per language server language; installed versions carry languageServers, and
# enabling or confirming the installation of a plugin returns displacePlugin for every enabled
# plugin that serves one of the same languages. It is on top of #38 (the logging event catalog
# generator is back, with update.delta.fallback_selected), squash-merged into main, on top of
# #37, squash-merged into main: markdown.resolveReference decides what a link or
# an image of a rendered Markdown document points at, for the web view previews. It is on top of
# #36, squash-merged into main: plugin settings read translations a package ships in
# l10n/<language>.json. It is on top of #35, squash-merged into main: build.detect skips the
# workspace's ignored paths, .gitignore patterns relative to the root that only match
# directories, by default every dot-named directory; build.resolveStoredOptions reports the list
# the local or team Build document sets, else the default, and build.editIgnoredPaths replaces or
# removes the local list. It is on top of #34 (workbench.chromeLayout.reduce setHidden hides a
# stripe entry and the layout keeps it in hidden), squash-merged into main, on top of #33,
# squash-merged into main: build.detect and automatic run discovery skip
# directories Git ignores (the .gitignore files inside the workspace and the info/exclude of each
# repository rooted there, a linked worktree's shared one included), so agent worktrees and local
# copies are no longer build or run roots; fingerprint scans are unchanged. It is on top of #32
# (inline SVG in Markdown keeps whitelisted drawing elements), squash-merged into main, on top of
# #31, squash-merged into main. #31 re-lands #30, which was merged into the branch
# of #28 after #28 itself had gone into main, and adds the host rules the desktop no longer keeps
# itself (processLifecycle gracefulStopRule, network.proxyPolicy exclusionRules,
# git.changedFileGroups, git.worktrees states and git.worktreeCreationPreview,
# plugins.installed.lifecycle, editor.groupLayout.*, workspace.rowSelection.reduce and
# workspace.projectTree.rows) in four new rule crates (50 in the workspace). It is on top of #28
# (34 more crates split out of lithe-core, 46 in the workspace; command names, JSON, error codes
# and the C header unchanged, except that a build system's source:"hostIntegration" is now
# refused as plugin.manifest.invalid), squash-merged into main, on top of #29 (cold
# managed runtimes may finish LSP initialization), squash-merged into main, on top of
# #27 (protocol, network, terminal, process, diff and github split into their own
# crates, keymap and action search moved into lithe-core-rules; command names, JSON, error codes
# and the C header unchanged), squash-merged into main, on top of #26 (community.discourse.*
# commands and the wasm build removed, every crate moved to rust/crates/<name without the lithe-
# prefix>/, the C header now at rust/crates/core/include/lithe_core.h), on top of #25 (the ai.*
# commands moved into the lithe-ai crate; command names, JSON and error codes unchanged), #24
# (rust/contracts and rust/fixtures are the only copy of the application contracts and fixtures,
# which desktop tests read through LITHE_CORE_FIXTURE_DIR) and
# #23 (Java, Maven and JDT special cases removed, execution.planLaunchCommand among them;
# run/start temporaryFiles may carry base64 bytes), squash-merged into main, on top of #22 (IDE find/replace,
# recovery, preferences, navigation, keymaps and Scratch lifecycle), squash-merged into main, on top of #21 (debug.setBreakpointsMuted, debug.planMemoryWindow and
# debug.locateMemoryWindow, runConfig.decideTitleAction), squash-merged into main, on top of #20
# (lsp.declarationOrUsages and the references operation's includeDeclaration, for Go to
# Declaration or Usages), #19 (MCP configuration and library commands removed) and #17: the plugin contract is one
# baseline with pluginAPIVersion and every capability, protocol and document version at 0, and
# the contract, plugin guides, reference and SDKs live only in shared/plugins; on top of #16 (reported Git queries folded in the console),
# #15 (git.write cherryPick, revert and reset fields), #14 (word-level changed ranges of diff
# rows), #13, #8, #7, #6 and #4.
PINNED_CORE_REVISION="c550c2bf10b4d82d2315e737bf83a007daafaa56"
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

# cgo's external MinGW linker already supplies the Windows system import libraries.
# winapi's supported switch avoids depending on libwinapi_* archives under a
# Cargo registry/build-script directory that is not part of the staged Core.
if [[ "$RUST_TARGET" == *-windows-gnu ]]; then
    export WINAPI_NO_BUNDLED_LIBRARIES=1
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
# The pinned checkout and a LITHE_CORE_RUST_DIR override share this target directory, and Cargo
# hashes a workspace member by its path inside the workspace, not by where the checkout is: both
# checkouts build every member, such as the event catalog in lithe-diagnostics, to the same
# files with the same fingerprint. Freshness is judged by modification times, so after the other
# checkout overwrote them, the files still look up to date and the staged library would carry
# the other checkout's code under this checkout's identity. The checkout that built the members
# last is recorded per target and profile; a different one cleans the workspace members, which
# are then built from it, while registry dependencies stay cached.
BUILT_FROM_FILE="$CARGO_TARGET_DIR_BASH/lithe-core-built-from-$RUST_TARGET-$PROFILE.txt"
if [[ "$(cat "$BUILT_FROM_FILE" 2>/dev/null || true)" != "$CORE_DIR" ]]; then
    cargo clean --manifest-path "$MANIFEST_NATIVE" --workspace \
        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" >&2
    mkdir -p "$CARGO_TARGET_DIR_BASH"
    printf '%s\n' "$CORE_DIR" > "$BUILT_FROM_FILE"
fi
cargo rustc --manifest-path "$MANIFEST_NATIVE" -p lithe-core --lib --crate-type staticlib \
    "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" \
    -- --print "native-static-libs=$NATIVE_LIBS_FILE_NATIVE" >&2
if [[ ! -s "$NATIVE_LIBS_FILE" ]]; then
    printf '%s\n' "rustc did not report the native libraries of liblithe_core.a." >&2
    exit 1
fi

install -m 0644 "$LIBRARY_DIR/liblithe_core.a" "$STAGE_DIR/lib/liblithe_core.a"
install -m 0644 "$CORE_DIR/rust/crates/core/include/lithe_core.h" "$STAGE_DIR/include/lithe_core.h"

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
    if [[ "$RUST_TARGET" == *-windows-gnu ]]; then
        printf 'winapi-import-libraries=mingw-system\n'
    fi
    if [[ "$RUST_TARGET" == *-apple-darwin ]]; then
        printf 'macos-deployment-target=%s\n' "$MACOSX_DEPLOYMENT_TARGET"
    fi
} > "$STAGE_DIR/identity.txt"
printf '%s\n' "$STAGE_DIR"
