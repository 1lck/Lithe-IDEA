// Real-ConPTY integration test for the multi-session terminal feature model.
//
// Windows CI only (builds to an empty main elsewhere). Exercises the full
// TerminalModel -> TerminalSession -> Win32TerminalTransport -> ConPTY stack
// against real cmd sessions, covering the behaviours issue #31 requires that
// the fake-transport unit tests cannot: concurrent sessions, per-session IO
// isolation, switching, interrupt (Ctrl+C), restart, and whole-process-tree
// teardown on closeAll().

#include "terminal_model.h"
#include "terminal_session.h"
#include "win32_terminal_transport.h"

#include <cassert>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <tlhelp32.h>
#endif

#ifdef _WIN32

namespace {

std::vector<DWORD> descendantProcesses(DWORD rootId) {
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return {};
    std::vector<std::pair<DWORD, DWORD>> edges;
    PROCESSENTRY32W entry{sizeof(PROCESSENTRY32W)};
    if (Process32FirstW(snapshot, &entry)) {
        do {
            edges.emplace_back(entry.th32ProcessID, entry.th32ParentProcessID);
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);

    std::vector<DWORD> result;
    std::vector<DWORD> pending{rootId};
    while (!pending.empty()) {
        const DWORD parent = pending.back();
        pending.pop_back();
        for (const auto& [pid, ppid] : edges) {
            if (ppid == parent) {
                result.push_back(pid);
                pending.push_back(pid);
            }
        }
    }
    return result;
}

std::string shellExecutable() {
    char value[32768]{};
    const DWORD length = GetEnvironmentVariableA("ComSpec", value, sizeof(value));
    return (length > 0 && length < sizeof(value)) ? std::string(value, length) : std::string("cmd.exe");
}

template <typename Predicate>
bool waitUntil(Predicate predicate, int timeoutMs, int stepMs = 25) {
    for (int elapsed = 0; elapsed < timeoutMs; elapsed += stepMs) {
        if (predicate()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(stepMs));
    }
    return predicate();
}

} // namespace

#endif

int main() {
#ifndef _WIN32
    return 0;
#else
    using namespace lithe::windows;
    using namespace lithe::windows::app;
    const DWORD selfPid = GetCurrentProcessId();

    TerminalModel model([]() -> std::unique_ptr<TerminalTransport> {
        return std::make_unique<Win32TerminalTransport>();
    });
    const TerminalShellSpec shell{shellExecutable(), {}};

    // --- multi-session start: two shells run concurrently ---
    const std::string a = model.create(shell, "", {});
    const std::string b = model.create(shell, "", {});
    assert(!a.empty() && !b.empty() && a != b);
    const auto expectRunning = [&](const std::string& id) {
        const bool reached = waitUntil([&] {
            const auto* session = model.find(id);
            return session != nullptr && session->state() == ProcessLifecycleState::Running;
        }, 15000);
        if (!reached) {
            const auto* session = model.find(id);
            std::cerr << "[terminal_integration] session " << id
                      << " did not reach Running within 15s; state="
                      << (session != nullptr ? std::to_string(static_cast<int>(session->state()))
                                             : std::string("null"))
                      << " descendants=" << descendantProcesses(selfPid).size()
                      << " buffer=[" << (session != nullptr ? session->render(400) : std::string()) << "]\n";
        }
        assert(reached);
    };
    expectRunning(a);
    expectRunning(b);
    assert(descendantProcesses(selfPid).size() >= 2);

    // --- IO + per-session isolation: output never crosses sessions ---
    model.send(a, "echo SESSION_A_MARKER_42\r\n");
    model.send(b, "echo SESSION_B_MARKER_88\r\n");
    assert(waitUntil([&] {
        return model.find(a)->render(65536).find("SESSION_A_MARKER_42") != std::string::npos;
    }, 15000));
    assert(waitUntil([&] {
        return model.find(b)->render(65536).find("SESSION_B_MARKER_88") != std::string::npos;
    }, 15000));
    assert(model.find(a)->render(65536).find("SESSION_B_MARKER_88") == std::string::npos);
    assert(model.find(b)->render(65536).find("SESSION_A_MARKER_42") == std::string::npos);

    // --- switching the active session ---
    assert(model.select(b));
    assert(model.currentId().has_value() && *model.currentId() == b);
    assert(model.select(a));
    assert(model.currentId().has_value() && *model.currentId() == a);

    // --- interrupt: a long-running foreground command in A is stopped by
    // Ctrl+C, and A accepts further input afterwards ---
    model.send(a, "ping -n 20 127.0.0.1\r\n");
    assert(waitUntil([&] {
        return model.find(a)->render(65536).find("Pinging 127.0.0.1") != std::string::npos;
    }, 15000));
    model.interrupt(a);
    model.send(a, "echo AFTER_INTERRUPT_7\r\n");
    assert(waitUntil([&] {
        return model.find(a)->render(65536).find("AFTER_INTERRUPT_7") != std::string::npos;
    }, 15000));

    // --- restart: A relaunches under a new launch generation and runs again ---
    model.restart(a);
    assert(waitUntil([&] {
        const auto* session = model.find(a);
        return session != nullptr && session->state() == ProcessLifecycleState::Running;
    }, 15000));

    // --- teardown: closeAll() (the workspace-switch / project-close path)
    // kills every session's whole process tree ---
    model.closeAll();
    assert(waitUntil([&] { return descendantProcesses(selfPid).empty(); }, 15000));
    assert(model.sessionIds().empty());

    return 0;
#endif
}
