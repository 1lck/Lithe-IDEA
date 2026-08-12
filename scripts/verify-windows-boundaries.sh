#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

SOURCE_FILES=(windows/**/*.h windows/**/*.cpp)
if rg -n 'SwiftUI|AppKit|\.swift(?:$|[^A-Za-z0-9_])|MacOS|Mac[A-Z]' $SOURCE_FILES; then
    print -u2 "Windows source must not reference the macOS application"
    exit 1
fi

PUBLIC_HEADERS=(windows/adapters/*.h windows/core/*.h windows/qt/*.h windows/winui/workbench_session.h)
if rg -n '\b(HANDLE|HPCON)\b|#include <windows\.h>|#include <winconpty\.h>' $PUBLIC_HEADERS; then
    print -u2 "Windows public ports must not expose Win32 handle types"
    exit 1
fi

if rg -n '#include\s*[<"](windows\.h|winrt/|Microsoft\.UI|Qt[A-Za-z0-9_/.-]*)' \
    windows/app/algorithms windows/app/features windows/app/persistence \
    windows/app/presentation windows/app/services; then
    print -u2 "Windows app layers must not depend on Win32, WinUI, or Qt"
    exit 1
fi

if rg -n '#include\s*[<"]core_client\.h[>"]' windows/qt; then
    print -u2 "Qt code must not include core_client.h directly"
    exit 1
fi

if rg -n '#include\s*[<"]core_client\.h[>"]' windows/winui; then
    print -u2 "WinUI code must not include core_client.h directly"
    exit 1
fi

required=(
    windows/core/core_client.cpp
    windows/core/core_worker_pool.cpp
    windows/adapters/win32_file_system.cpp
    windows/adapters/win32_file_storage.cpp
    windows/adapters/win32_directory_watcher.cpp
    windows/adapters/win32_process_session.cpp
    windows/adapters/win32_process_runner.cpp
    windows/adapters/win32_terminal_transport.cpp
    windows/adapters/win32_runtime_locator.cpp
    windows/adapters/win32_secure_store.cpp
    windows/adapters/win32_http_transport.cpp
    windows/adapters/win32_authenticode_verifier.cpp
    windows/app/services/ai_commit_service.cpp
    windows/app/services/windows_update_service.cpp
    windows/adapters/win32_key_value_store.cpp
    windows/packaging/update_helper.cpp
    windows/qt/workbench_code_editor.cpp
    windows/qt/workbench_window.cpp
    windows/winui/App.xaml
    windows/winui/MainWindow.xaml
    windows/winui/MainWindow.xaml.cpp
    windows/winui/workbench_session.cpp
    windows/winui/Lithe.WinUI.vcxproj
)
for file in $required; do
    [[ -f "$file" ]] || { print -u2 "Missing Windows implementation: $file"; exit 1; }
done

print "Windows boundary verification passed: UI/Core/adapters are isolated"
