#include "win32_terminal_transport.h"

#include <cassert>
#include <chrono>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <tlhelp32.h>
#endif

namespace {

#ifdef _WIN32

struct ProcessEntry {
    DWORD id = 0;
    DWORD parentId = 0;
    std::wstring name;
};

std::vector<ProcessEntry> processSnapshot() {
    std::vector<ProcessEntry> result;
    const auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return result;

    PROCESSENTRY32W entry{sizeof(PROCESSENTRY32W)};
    if (Process32FirstW(snapshot, &entry)) {
        do {
            result.push_back({entry.th32ProcessID, entry.th32ParentProcessID, entry.szExeFile});
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return result;
}

std::vector<DWORD> descendants(DWORD rootId) {
    const auto processes = processSnapshot();
    std::vector<DWORD> result;
    std::vector<DWORD> pending{rootId};
    while (!pending.empty()) {
        const auto parentId = pending.back();
        pending.pop_back();
        for (const auto& process : processes) {
            if (process.parentId != parentId) continue;
            result.push_back(process.id);
            pending.push_back(process.id);
        }
    }
    return result;
}

struct VisibleWindowSearch {
    DWORD processId = 0;
    bool visible = false;
};

BOOL CALLBACK findVisibleWindow(HWND window, LPARAM parameter) {
    auto& search = *reinterpret_cast<VisibleWindowSearch*>(parameter);
    DWORD processId = 0;
    GetWindowThreadProcessId(window, &processId);
    if (processId == search.processId && IsWindowVisible(window)) {
        search.visible = true;
        return FALSE;
    }
    return TRUE;
}

bool hasVisibleWindow(DWORD processId) {
    VisibleWindowSearch search{processId, false};
    EnumWindows(findVisibleWindow, reinterpret_cast<LPARAM>(&search));
    return search.visible;
}

std::string pingExecutable() {
    char systemRoot[MAX_PATH] = {};
    const DWORD length = GetEnvironmentVariableA("SystemRoot", systemRoot, sizeof(systemRoot));
    return (length > 0 && length < sizeof(systemRoot))
        ? std::string(systemRoot) + "\\System32\\ping.exe"
        : std::string("ping.exe");
}

#endif

}

int main() {
#ifndef _WIN32
    return 0;
#else
    lithe::windows::Win32TerminalTransport terminal;
    lithe::windows::ProcessRequest request;
    request.operationID = "terminal-lifecycle-test";
    // Use ping (a deterministic ~30s process) instead of `cmd /d /k ver`:
    // commandLine() quotes each argument, so `ver` became `"ver"` and cmd
    // treated it as an unknown program (and sometimes failed to recognize the
    // quoted `/k` switch), nondeterministically exiting on a headless CI
    // ConPTY and failing assert(isRunning()). ping has no quoting pitfalls and
    // no visible window, so the transport's start/descendants/stop checks stay
    // stable on CI.
    request.executablePath = pingExecutable();
    request.arguments = {"-n", "31", "127.0.0.1"};
    terminal.setErrorHandler([](const std::string& error) {
        std::cerr << "Terminal startup error: " << error << '\n';
    });

    terminal.start(request);
    for (int index = 0; index < 100 && !terminal.isRunning(); ++index) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    assert(terminal.isRunning());

    const auto processId = GetCurrentProcessId();
    const auto runningDescendants = descendants(processId);
    assert(!runningDescendants.empty());
    for (const auto childId : runningDescendants) assert(!hasVisibleWindow(childId));

    terminal.stop();
    assert(!terminal.isRunning());
    for (int index = 0; index < 100 && !descendants(processId).empty(); ++index) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    assert(descendants(processId).empty());
    return 0;
#endif
}
