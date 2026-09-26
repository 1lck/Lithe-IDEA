#!/usr/bin/env bash
#
# 从 macOS/Linux 交叉编译 Linux GPUI 工作台（linux/）到 Windows。
#
# 只支持 `x86_64-pc-windows-gnu`（MinGW-w64）目标：MSVC 目标的 C 依赖需要
# `lib.exe` 等 MSVC 工具链，无法在非 Windows 主机上构建。产物是可执行的
# `lithe-linux.exe`，运行期依赖同目录下的 MinGW 运行时 DLL（见脚本结尾提示）。
#
# 只支持 debug 构建：上游 `gpui-pre-windows` 的 release 构建会用 `fxc.exe`
# 编译 HLSL shader，而 fxc 来自 Windows SDK 且通过注册表定位，非 Windows
# 主机无法完成。Windows 上的 release 请在 Windows 主机使用 cargo 构建。
#
# 用法：
#   scripts/build-gpui-windows.sh [--debug] [--target <triple>] [-- <cargo 额外参数>]
#
# 依赖（缺失时脚本给出安装提示并退出）：
#   - rustup 且已安装目标：`rustup target add x86_64-pc-windows-gnu`
#   - MinGW-w64 工具链：`x86_64-w64-mingw32-gcc` / `g++` / `ar`
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROFILE="debug"
TARGET="x86_64-pc-windows-gnu"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            PROFILE="release"
            shift
            ;;
        --debug)
            PROFILE="debug"
            shift
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ "$TARGET" != *"-windows-gnu" ]]; then
    printf '==> Error: only *-windows-gnu targets are supported on a non-Windows host (got %s).\n' "$TARGET" >&2
    printf '    MSVC targets require the MSVC toolchain, which is unavailable here.\n' >&2
    exit 2
fi

# 上游 gpui-pre-windows 在 release 下用 fxc.exe 编译 shader，而 fxc 由 Windows
# SDK 通过注册表定位；非 Windows 主机必然失败（缺少 shaders_bytes.rs）。
if [[ "$PROFILE" == "release" ]]; then
    printf '==> Error: --release is not supported by this cross-compilation script.\n' >&2
    printf '    gpui-pre-windows compiles HLSL with fxc.exe (Windows SDK) in release builds.\n' >&2
    printf '    Use a Windows host for release, or build with --debug here.\n' >&2
    exit 2
fi

# MinGW 工具链按目标架构选择前缀；当前仅 x86_64 可用。
case "$TARGET" in
    x86_64-*-windows-gnu)
        MINGW_PREFIX="x86_64-w64-mingw32"
        ;;
    *)
        printf '==> Error: unsupported MinGW target %s.\n' "$TARGET" >&2
        exit 2
        ;;
esac

CC_BIN="${MINGW_PREFIX}-gcc"
CXX_BIN="${MINGW_PREFIX}-g++"
AR_BIN="${MINGW_PREFIX}-ar"

missing=0
for tool in "$CC_BIN" "$CXX_BIN" "$AR_BIN"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '==> Error: %s not found on PATH.\n' "$tool" >&2
        missing=1
    fi
done
if [[ "$missing" -ne 0 ]]; then
    printf '    Install MinGW-w64, e.g. Debian/Ubuntu: sudo apt-get install mingw-w64\n' >&2
    printf '    or macOS (Homebrew): brew install mingw-w64\n' >&2
    exit 2
fi

# C/C++ 依赖（gpui/wgpu/alacritty_terminal 等）经 cc-rs 构建，需显式指定交叉编译器。
# 变量名把目标 triple 的 `-` 换成 `_`，这是 cc-rs 的约定。
TARGET_ENV="${TARGET//-/_}"
export "CC_${TARGET_ENV}=$CC_BIN"
export "CXX_${TARGET_ENV}=$CXX_BIN"
export "AR_${TARGET_ENV}=$AR_BIN"
# 交叉链接时 rustc 也需要知道链接器（部分依赖用 gcc 直接驱动链接）。
export "CARGO_TARGET_${TARGET_ENV^^}_LINKER=$CC_BIN"

cd "$ROOT_DIR"

# 与 build-linux.sh 隔离产物目录，避免 Windows 目标污染本机 Linux 构建缓存。
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/linux/target}"
export CARGO_TARGET_DIR

BUILD_ARGS=(build --manifest-path "$ROOT_DIR/linux/Cargo.toml" -p lithe-linux --target "$TARGET")

if [[ "$PROFILE" == "release" ]]; then
    BUILD_ARGS+=(--release)
fi

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    BUILD_ARGS+=("${EXTRA_ARGS[@]}")
fi

printf '==> Building Lithe GPUI frontend for Windows (%s, %s)...\n' "$TARGET" "$PROFILE"
cargo "${BUILD_ARGS[@]}"

OUTPUT_BIN="$CARGO_TARGET_DIR/$TARGET/$PROFILE/lithe-linux.exe"
if [[ ! -f "$OUTPUT_BIN" ]]; then
    printf '==> Error: output binary not found at %s\n' "$OUTPUT_BIN" >&2
    exit 1
fi

printf '==> Build successful: %s\n' "$OUTPUT_BIN"
printf '==> Note: copy the MinGW runtime DLLs next to the exe on the target machine\n'
printf '    (typically libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll).\n'
