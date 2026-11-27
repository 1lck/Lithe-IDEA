#!/usr/bin/env bash
# Builds lithe-remote-server, the host server of remote workspaces, for the Linux targets the
# desktop client uploads to SSH hosts and containers, and stages it under
# .artifacts/desktop/remote-server/:
#
# Usage: scripts/desktop/build-remote-server.sh
#
#   <target>/lithe-remote-server   the static release executable of that target
#   remote-server-manifest.json    core revision, server version, rustc, and the size and SHA-256
#                                  of each executable
#
# The server comes from the core checkout scripts/desktop/build-desktop-core.sh prepares: the
# pinned revision, or LITHE_CORE_RUST_DIR. Both targets are musl and link with the rust-lld that
# ships with Rust, so the same command works on macOS, Linux and Windows without Docker, zig or a
# cross C toolchain. The Rust standard library of each target must be installed
# (rustup target add <target>).
#
# Only the server feature of lithe-remote is enabled, and Core's release profile applies. The
# executables are uploaded to other machines, so --locked accepts only the dependencies of Core's
# Cargo.lock. There is no size limit: security and features come before size (#2231, D9);
# scripts/desktop/verify/verify-remote-server-artifacts.mjs reports the sizes and checks the
# artifacts.
#
# The staging directory is build state of this worktree. Nothing at runtime reads or writes it.
#
# The staging directory is the only line written to standard output, so a caller can read it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# rustup picks the toolchain from the directory cargo runs in; rust-toolchain.toml of this
# repository pins the compiler, as for build-desktop-core.sh.
cd "$ROOT_DIR"

# Keep in step with ServerTarget::rust_target of the Linux hosts in Core
# (rust/crates/remote/src/client/bootstrap.rs) and with SERVER_TARGETS of the verify script,
# which fails when the manifest names a different set.
TARGETS=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl)
SERVER_BINARY="lithe-remote-server"

if [[ $# -gt 0 ]]; then
    printf '%s\n' "Usage: $0" >&2
    exit 2
fi

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

# Every manifest value is written as a JSON string or number without escaping, so it must not
# contain characters that would need escaping.
require_plain() {
    local name="$1" value="$2" pattern="$3"
    if [[ ! "$value" =~ $pattern ]]; then
        printf 'Unexpected %s for the remote server manifest: %s\n' "$name" "$value" >&2
        exit 1
    fi
}

SYSROOT="$(rustc --print sysroot)"
MISSING_TARGETS=()
for target in "${TARGETS[@]}"; do
    if [[ ! -d "$SYSROOT/lib/rustlib/$target/lib" ]]; then
        MISSING_TARGETS+=("$target")
    fi
done
if [[ ${#MISSING_TARGETS[@]} -gt 0 ]]; then
    printf 'The Rust standard library of %s is not installed for %s.\n' \
        "${MISSING_TARGETS[*]}" "$(rustc -V)" >&2
    printf 'Run: rustup target add %s\n' "${MISSING_TARGETS[*]}" >&2
    exit 1
fi

CORE_DIR="$("$ROOT_DIR/scripts/desktop/build-desktop-core.sh" --checkout-only)"
if [[ -n "${LITHE_CORE_RUST_DIR:-}" ]]; then
    CORE_SOURCE="override"
else
    CORE_SOURCE="pinned"
fi
MANIFEST="$CORE_DIR/rust/Cargo.toml"
MANIFEST_NATIVE="$(native_path "$MANIFEST")"
CORE_REVISION="$(git -C "$CORE_DIR" rev-parse HEAD)"
CORE_DIRTY="clean"
if [[ -n "$(git -C "$CORE_DIR" status --porcelain --untracked-files=normal -- rust)" ]]; then
    CORE_DIRTY="dirty"
fi

ARTIFACTS_DIR="$ROOT_DIR/.artifacts/desktop"
STAGE_DIR="$ARTIFACTS_DIR/remote-server"
# The same Cargo target directory as build-desktop-core.sh: the musl builds go below
# target/<triple>/ and share the registry dependencies' sources with the desktop Core.
CARGO_TARGET_DIR_BASH="$ARTIFACTS_DIR/lithe-core-rust/target"
export CARGO_TARGET_DIR
CARGO_TARGET_DIR="$(native_path "$CARGO_TARGET_DIR_BASH")"
unset MACOSX_DEPLOYMENT_TARGET
# Core's release profile strips; on macOS that also strips the host proc-macro dylibs and rustc
# then cannot load serde_derive. Build scripts and proc macros never ship (build-desktop-core.sh).
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP:-false}"

SERVER_PACKAGE_ID="$(cargo pkgid --manifest-path "$MANIFEST_NATIVE" --locked lithe-remote)"
SERVER_VERSION="${SERVER_PACKAGE_ID##*[#@]}"
RUSTC_VERSION="$(rustc -V)"
require_plain "core revision" "$CORE_REVISION" '^[0-9a-f]{40}$'
require_plain "server version" "$SERVER_VERSION" '^[0-9A-Za-z][0-9A-Za-z.+-]*$'
require_plain "rustc version" "$RUSTC_VERSION" '^[0-9A-Za-z .:()+-]+$'

TARGET_ARGS=()
for target in "${TARGETS[@]}"; do
    # The musl targets are self-contained: rust-lld links the C runtime and libunwind that come
    # with the target's standard library, and no C compiler is involved.
    linker_variable="CARGO_TARGET_$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')_LINKER"
    export "$linker_variable=rust-lld"
    # A pinned checkout and a LITHE_CORE_RUST_DIR override share the target directory and Cargo
    # cannot tell their workspace members apart; see build-desktop-core.sh. The same per-target
    # record tells which checkout built the members last.
    built_from_file="$CARGO_TARGET_DIR_BASH/lithe-core-built-from-$target-release.txt"
    if [[ "$(cat "$built_from_file" 2>/dev/null || true)" != "$CORE_DIR" ]]; then
        cargo clean --manifest-path "$MANIFEST_NATIVE" --workspace --release --target "$target" >&2
        mkdir -p "$CARGO_TARGET_DIR_BASH"
        printf '%s\n' "$CORE_DIR" > "$built_from_file"
    fi
    TARGET_ARGS+=(--target "$target")
done
# Build both Linux musl targets in one Cargo invocation so proc-macros and build scripts run once
# and target compilation shares CPU cores.
cargo build --manifest-path "$MANIFEST_NATIVE" --locked --release "${TARGET_ARGS[@]}" \
    -p lithe-remote --bin "$SERVER_BINARY" --no-default-features --features server >&2
for target in "${TARGETS[@]}"; do
    if [[ ! -f "$CARGO_TARGET_DIR_BASH/$target/release/$SERVER_BINARY" ]]; then
        printf 'cargo did not build %s for %s.\n' "$SERVER_BINARY" "$target" >&2
        exit 1
    fi
done

# Staged only after every target built, so a failed build never leaves a manifest that names a
# mix of new and old executables. The directory belongs to this script alone.
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ARTIFACT_ENTRIES=()
for target in "${TARGETS[@]}"; do
    mkdir -p "$STAGE_DIR/$target"
    staged="$STAGE_DIR/$target/$SERVER_BINARY"
    install -m 0755 "$CARGO_TARGET_DIR_BASH/$target/release/$SERVER_BINARY" "$staged"
    size="$(wc -c < "$staged" | tr -d '[:space:]')"
    sha256="$(sha256_of "$staged")"
    require_plain "size" "$size" '^[0-9]+$'
    require_plain "SHA-256" "$sha256" '^[0-9a-f]{64}$'
    ARTIFACT_ENTRIES+=("$(printf '    {"target": "%s", "path": "%s/%s", "size": %s, "sha256": "%s"}' \
        "$target" "$target" "$SERVER_BINARY" "$size" "$sha256")")
done
{
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "coreRevision": "%s",\n' "$CORE_REVISION"
    printf '  "coreWorktree": "%s",\n' "$CORE_DIRTY"
    printf '  "coreSource": "%s",\n' "$CORE_SOURCE"
    printf '  "serverVersion": "%s",\n' "$SERVER_VERSION"
    printf '  "rustc": "%s",\n' "$RUSTC_VERSION"
    printf '  "profile": "release",\n'
    printf '  "artifacts": [\n'
    for index in "${!ARTIFACT_ENTRIES[@]}"; do
        separator=","
        if [[ "$index" -eq $((${#ARTIFACT_ENTRIES[@]} - 1)) ]]; then
            separator=""
        fi
        printf '%s%s\n' "${ARTIFACT_ENTRIES[$index]}" "$separator"
    done
    printf '  ]\n'
    printf '}\n'
} > "$STAGE_DIR/remote-server-manifest.json"
printf '%s\n' "$STAGE_DIR"
