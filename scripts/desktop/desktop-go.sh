#!/usr/bin/env bash
# Runs a Go command in desktop/ with cgo linked to the staged Lithe-core-rust library:
#
# Usage:
#   scripts/desktop/desktop-go.sh test ./...
#   scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe ./cmd/lithe
#   GOARCH=amd64 scripts/desktop/desktop-go.sh build ./cmd/lithe
#   scripts/desktop/desktop-go.sh --exec PROGRAM [ARGS...]
#   scripts/desktop/desktop-go.sh --print-core-stage
#
# The core is staged before every run so a changed pin or local LITHE_CORE_RUST_DIR cannot leave
# cgo linking the previous revision. GOOS must be the host OS; GOARCH selects a supported core
# target. The --exec mode keeps the same directory, core staging and cgo environment for tools
# such as Viva that build the application themselves. The --print-core-stage mode stages the core
# for that target and prints only its staging directory; callers that need the staged core without
# running Go use it instead of build-desktop-core.sh, whose default is the rustc host target.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Go parses CGO_* flags with quoted.Split, so quote the entire argument, not
# just the path portion. This also covers worktrees and Cargo homes with spaces.
cgo_arg() {
    local value="$1"
    if [[ "$value" == *'"'* && "$value" == *"'"* ]]; then
        printf '%s\n' 'A cgo path contains both kinds of quotation mark.' >&2
        return 1
    elif [[ "$value" == *'"'* ]]; then
        printf "'%s'" "$value"
    else
        printf '"%s"' "$value"
    fi
}

GOOS="$(go env GOOS)"
GOHOSTOS="$(go env GOHOSTOS)"
if [[ "$GOOS" != "$GOHOSTOS" ]]; then
    printf '%s\n' "Cross-OS builds are not supported: GOOS=$GOOS but the Go host is $GOHOSTOS." >&2
    exit 2
fi
GOARCH="${GOARCH:-$(go env GOARCH)}"
export GOOS GOARCH

case "$GOOS:$GOARCH" in
    darwin:arm64) MAPPED_CORE_TARGET="aarch64-apple-darwin" ;;
    darwin:amd64) MAPPED_CORE_TARGET="x86_64-apple-darwin" ;;
    linux:amd64) MAPPED_CORE_TARGET="x86_64-unknown-linux-gnu" ;;
    linux:arm64) MAPPED_CORE_TARGET="aarch64-unknown-linux-gnu" ;;
    windows:amd64) MAPPED_CORE_TARGET="x86_64-pc-windows-gnu" ;;
    windows:arm64)
        printf '%s\n' 'Windows arm64 is not supported; use the x86_64 Windows client.' >&2
        exit 2
        ;;
    *)
        printf '%s\n' "No Lithe-core-rust target is configured for GOOS=$GOOS GOARCH=$GOARCH." >&2
        exit 2
        ;;
esac
if [[ -z "${LITHE_CORE_TARGET:-}" ]]; then
    export LITHE_CORE_TARGET="$MAPPED_CORE_TARGET"
fi

PROFILE="${LITHE_DESKTOP_CORE_PROFILE:-debug}"
PROFILE_FLAG="--debug"
if [[ "$PROFILE" == "release" ]]; then
    PROFILE_FLAG="--release"
elif [[ "$PROFILE" != "debug" ]]; then
    printf '%s\n' "LITHE_DESKTOP_CORE_PROFILE must be debug or release, not $PROFILE." >&2
    exit 2
fi

if [[ "$GOOS" == "darwin" ]]; then
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
else
    unset MACOSX_DEPLOYMENT_TARGET
fi
if [[ "${1:-}" == "--print-core-stage" && $# -ne 1 ]]; then
    printf '%s\n' "Usage: $0 --print-core-stage" >&2
    exit 2
fi
STAGE_DIR="$("$ROOT_DIR/scripts/desktop/build-desktop-core.sh" "$PROFILE_FLAG")"
if [[ "${1:-}" == "--print-core-stage" ]]; then
    printf '%s\n' "$STAGE_DIR"
    exit 0
fi
# Packaging reads the staged helper to embed it; development runs use it directly so the IDE
# Connection page is testable without a packaged build.
export LITHE_CORE_STAGE_DIR="$STAGE_DIR"
# The plugin contract and the application fixtures have one copy each, in the core checkout that
# was just built: tests read them through internal/contractfixture. This mirrors the checkout
# build-desktop-core.sh uses.
if [[ -n "${LITHE_CORE_RUST_DIR:-}" ]]; then
    CORE_CHECKOUT="$(cd "$LITHE_CORE_RUST_DIR" && pwd -P)"
else
    CORE_CHECKOUT="$ROOT_DIR/.artifacts/desktop/lithe-core-rust/source"
fi
LITHE_PLUGIN_CONTRACT_DIR="$(native_path "$CORE_CHECKOUT/shared/plugins/contract/v1")"
export LITHE_PLUGIN_CONTRACT_DIR
LITHE_CORE_FIXTURE_DIR="$(native_path "$CORE_CHECKOUT/rust/fixtures")"
export LITHE_CORE_FIXTURE_DIR
if [[ -x "$STAGE_DIR/bin/lithe-mcp" ]]; then
    export LITHE_IDE_HELPER="$STAGE_DIR/bin/lithe-mcp"
elif [[ -x "$STAGE_DIR/bin/lithe-mcp.exe" ]]; then
    export LITHE_IDE_HELPER="$STAGE_DIR/bin/lithe-mcp.exe"
fi

export CGO_ENABLED=1
CGO_INCLUDE_DIR="$(native_path "$STAGE_DIR/include")"
CGO_LIBRARY_DIR="$(native_path "$STAGE_DIR/lib")"
NATIVE_STATIC_LIBS="$(<"$STAGE_DIR/native-static-libs.txt")"
# Rust's Windows staticlib can name import archives supplied by Cargo crates,
# not just system libraries. Cargo records each crate's native search path in
# its target-specific build output; Go's external linker needs those paths too.
# Do not infer registry versions or copy mutable Cargo files into the app bundle.
NATIVE_SEARCH_FLAGS=""
CORE_LINK_INPUTS=("$STAGE_DIR/lib/liblithe_core.a" "$STAGE_DIR/include/lithe_core.h" "$STAGE_DIR/native-static-libs.txt")
if [[ "$GOOS" == "windows" ]]; then
    CARGO_HOST_TARGET="$(rustc -vV | sed -n 's/^host: //p')"
    CARGO_BUILD_ROOT="$ROOT_DIR/.artifacts/desktop/lithe-core-rust/target"
    if [[ "$LITHE_CORE_TARGET" != "$CARGO_HOST_TARGET" ]]; then
        CARGO_BUILD_ROOT="$CARGO_BUILD_ROOT/$LITHE_CORE_TARGET"
    fi
    CARGO_BUILD_ROOT="$CARGO_BUILD_ROOT/$PROFILE/build"
    read -r -a NATIVE_ARGS <<< "$NATIVE_STATIC_LIBS"
    FOUND_NAMES=()
    FOUND_ARCHIVES=()
    for output in "$CARGO_BUILD_ROOT"/*/output; do
        [[ -f "$output" ]] || continue
        while IFS= read -r line; do
            line="${line%$'\r'}"
            case "$line" in
                cargo:rustc-link-search=native=*) native_dir="${line#cargo:rustc-link-search=native=}" ;;
                cargo::rustc-link-search=native=*) native_dir="${line#cargo::rustc-link-search=native=}" ;;
                *) continue ;;
            esac
            native_dir="$(cygpath -u "$native_dir")"
            used_dir=false
            for arg in "${NATIVE_ARGS[@]}"; do
                case "$arg" in -l*) lib_name="${arg#-l}" ;; *) continue ;; esac
                archive="$native_dir/lib$lib_name.a"
                [[ -f "$archive" ]] || continue
                for i in "${!FOUND_NAMES[@]}"; do
                    if [[ "${FOUND_NAMES[$i]}" == "$lib_name" ]] && ! cmp -s "$archive" "${FOUND_ARCHIVES[$i]}"; then
                        printf 'Conflicting Cargo import libraries for %s: %s and %s\n' "$lib_name" "$archive" "${FOUND_ARCHIVES[$i]}" >&2
                        exit 1
                    fi
                done
                FOUND_NAMES+=("$lib_name")
                FOUND_ARCHIVES+=("$archive")
                CORE_LINK_INPUTS+=("$archive")
                used_dir=true
            done
            if [[ "$used_dir" == true ]]; then
                NATIVE_SEARCH_FLAGS="$NATIVE_SEARCH_FLAGS $(cgo_arg "-L$(native_path "$native_dir")")"
            fi
        done < "$output"
    done
fi
# Go does not track external C archives in its build cache (go help cache).
# Bind cgo's action identity to the bytes actually staged, including Cargo's
# Windows import archives. Unchanged inputs retain the ordinary Go cache;
# no global cache cleaning or forced rebuild is needed.
if command -v sha256sum >/dev/null 2>&1; then
    CORE_HASH_COMMAND=(sha256sum)
else
    CORE_HASH_COMMAND=(shasum -a 256)
fi
CORE_LINK_ID="$(
    for input in "${CORE_LINK_INPUTS[@]}"; do
        "${CORE_HASH_COMMAND[@]}" < "$input" || exit 1
    done | "${CORE_HASH_COMMAND[@]}" | cut -d ' ' -f 1
)"
CGO_CFLAGS="${CGO_CFLAGS:-} $(cgo_arg "-I$CGO_INCLUDE_DIR") -DLITHE_CORE_LINK_$CORE_LINK_ID=1"
export CGO_CFLAGS
# GNU ld and MinGW resolve static archives from left to right, so rustc's native libraries must
# follow liblithe_core.a, which depends on them.
CGO_LDFLAGS="${CGO_LDFLAGS:-} $(cgo_arg "-L$CGO_LIBRARY_DIR") -llithe_core $NATIVE_SEARCH_FLAGS $NATIVE_STATIC_LIBS"
export CGO_LDFLAGS

cd "$ROOT_DIR/desktop"
if [[ "${1:-}" == "--exec" ]]; then
    if [[ $# -lt 2 ]]; then
        printf '%s\n' "Usage: $0 --exec PROGRAM [ARGS...]" >&2
        exit 2
    fi
    shift
    exec "$@"
fi
exec go "$@"
