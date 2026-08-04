#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

SOURCE_FILES=(windows/**/*.h windows/**/*.cpp)
if rg -n 'SwiftUI|AppKit|\.swift|MacOS|Mac[A-Z]' $SOURCE_FILES; then
    print -u2 "Windows source must not reference the macOS application"
    exit 1
fi

PUBLIC_HEADERS=(windows/adapters/*.h windows/core/*.h windows/qt/*.h)
if rg -n '\b(HANDLE|HPCON)\b|#include <windows\.h>|#include <winconpty\.h>' $PUBLIC_HEADERS; then
    print -u2 "Windows public ports must not expose Win32 handle types"
    exit 1
fi

required=(
    windows/core/core_client.cpp
    windows/adapters/win32_file_system.cpp
    windows/adapters/win32_directory_watcher.cpp
    windows/adapters/win32_process_session.cpp
    windows/adapters/win32_process_runner.cpp
    windows/adapters/win32_terminal_transport.cpp
    windows/adapters/win32_runtime_locator.cpp
    windows/adapters/win32_key_value_store.cpp
    windows/qt/workbench_window.cpp
)
for file in $required; do
    [[ -f "$file" ]] || { print -u2 "Missing Windows implementation: $file"; exit 1; }
done

print "Windows boundary verification passed: Qt/Core/adapters are isolated"
