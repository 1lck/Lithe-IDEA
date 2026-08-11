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
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cwchar>
#include <iostream>
#include <map>
#include <optional>
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

// Locale-independent way to confirm a foreground command is actually running
// (the "Pinging ..." text that ping prints is localized, so it cannot be
// matched on non-English systems).
bool hasDescendantExecutable(DWORD rootId, const wchar_t* name) {
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return false;
    std::map<DWORD, std::wstring> exeNames;
    std::multimap<DWORD, DWORD> children;
    PROCESSENTRY32W entry{sizeof(PROCESSENTRY32W)};
    if (Process32FirstW(snapshot, &entry)) {
        do {
            exeNames[entry.th32ProcessID] = entry.szExeFile;
            children.emplace(entry.th32ParentProcessID, entry.th32ProcessID);
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);

    std::vector<DWORD> pending{rootId};
    while (!pending.empty()) {
        const DWORD parent = pending.back();
        pending.pop_back();
        auto range = children.equal_range(parent);
        for (auto it = range.first; it != range.second; ++it) {
            if (_wcsicmp(exeNames[it->second].c_str(), name) == 0) return true;
            pending.push_back(it->second);
        }
    }
    return false;
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

// Parses the screen-buffer dimensions out of `mode con` output. The labels are
// localized ("Lines"/"Columns" vs "行"/"列"), so instead of matching keys we
// find the separator line of '-' characters and take the first two integers
// that follow it; on every locale `mode con` reports lines before columns.
std::optional<std::pair<int, int>> modeDimensions(const std::string& text) {
    std::size_t i = 0;
    while (i < text.size()) {
        const std::size_t eol = text.find('\n', i);
        const std::string line =
            text.substr(i, eol == std::string::npos ? std::string::npos : eol - i);
        bool allDashes = !line.empty();
        for (char ch : line) {
            if (ch != '-') { allDashes = false; break; }
        }
        if (allDashes) {
            int found = 0;
            int first = 0;
            int second = 0;
            std::size_t j = eol == std::string::npos ? text.size() : eol + 1;
            while (j < text.size() && found < 2) {
                if (std::isdigit(static_cast<unsigned char>(text[j]))) {
                    int value = 0;
                    while (j < text.size() && std::isdigit(static_cast<unsigned char>(text[j]))) {
                        value = value * 10 + (text[j] - '0');
                        ++j;
                    }
                    if (found == 0) first = value;
                    else second = value;
                    ++found;
                } else {
                    ++j;
                }
            }
            if (found == 2) return std::make_pair(first, second);
        }
        if (eol == std::string::npos) break;
        i = eol + 1;
    }
    return std::nullopt;
}

// True if the emulator grid contains a cell rendered with a red foreground
// (fgDefault off, R notably above G/B) — direct proof an SGR color code from a
// real cmd session reached the emulator grid.
bool hasRedForegroundCell(const lithe::windows::app::TerminalSession& session) {
    const auto& emulator = session.emulator();
    const int totalRows = emulator.scrollbackLineCount() + emulator.rows();
    for (int row = 0; row < totalRows; ++row) {
        for (int col = 0; col < emulator.cols(); ++col) {
            const auto& cell = emulator.cell(row, col);
            if (!cell.fgDefault && cell.fgRed > 200 && cell.fgGreen < 80 && cell.fgBlue < 80) {
                return true;
            }
        }
    }
    return false;
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

    // --- direct transport probe: does output reach the handler at all? ---
    {
        Win32TerminalTransport probe;
        std::string collected;
        probe.setOutputHandler([&](const std::string& bytes) { collected += bytes; });
        probe.setErrorHandler([](const std::string& msg) {
            std::cerr << "[probe] error: " << msg << "\n";
        });
        probe.setLifecycleHandler([](const ProcessLifecycleEvent& e) {
            std::cerr << "[probe] lifecycle state=" << static_cast<int>(e.state) << "\n";
        });
        ProcessRequest preq;
        preq.operationID = "probe";
        preq.executablePath = shellExecutable();
        preq.keepsStandardInputOpen = true;
        probe.start(preq);
        waitUntil([&] { return probe.isRunning(); }, 10000);
        probe.send("echo PROBE_MARKER_9\r\n");
        const bool sawProbe = waitUntil([&] {
            return collected.find("PROBE_MARKER_9") != std::string::npos;
        }, 10000);
        std::cerr << "[probe] running=" << probe.isRunning()
                  << " sawMarker=" << sawProbe
                  << " collectedSize=" << collected.size()
                  << " collected=[" << collected.substr(0, 400) << "]\n";
        probe.stop();
    }

    TerminalModel model([]() -> std::unique_ptr<TerminalTransport> {
        return std::make_unique<Win32TerminalTransport>();
    });
    const TerminalShellSpec shell{shellExecutable(), {}};

    // --- multi-session start: two shells run concurrently ---
    std::cerr << "[phase] creating sessions\n";
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
    std::cerr << "[phase] sessions running\n";

    // --- IO + per-session isolation: output never crosses sessions ---
    const bool sentA = model.send(a, "echo SESSION_A_MARKER_42\r\n");
    const bool sentB = model.send(b, "echo SESSION_B_MARKER_88\r\n");
    const auto findMarker = [&](const std::string& id, const std::string& marker) {
        const bool reached = waitUntil([&] {
            return model.find(id) != nullptr &&
                   model.find(id)->render(65536).find(marker) != std::string::npos;
        }, 15000);
        if (!reached) {
            std::cerr << "[terminal_integration] marker '" << marker << "' not seen in " << id
                      << "; sentA=" << sentA << " sentB=" << sentB
                      << " state=" << (model.find(id) != nullptr
                                         ? std::to_string(static_cast<int>(model.find(id)->state()))
                                         : std::string("null"))
                      << " buffer=[" << (model.find(id) != nullptr ? model.find(id)->render(65536)
                                                                   : std::string())
                      << "]\n";
        }
        return reached;
    };
    assert(findMarker(a, "SESSION_A_MARKER_42"));
    assert(findMarker(b, "SESSION_B_MARKER_88"));
    assert(model.find(a)->render(65536).find("SESSION_B_MARKER_88") == std::string::npos);
    assert(model.find(b)->render(65536).find("SESSION_A_MARKER_42") == std::string::npos);
    std::cerr << "[phase] markers isolated\n";

    // --- switching the active session ---
    assert(model.select(b));
    assert(model.currentId().has_value() && *model.currentId() == b);
    assert(model.select(a));
    assert(model.currentId().has_value() && *model.currentId() == a);
    std::cerr << "[phase] switched\n";

    // --- 6.1: SGR color reaches the emulator grid through the real ConPTY
    // stack. cmd has no `echo -e`, but `prompt $E` expands to a raw ESC byte in
    // the prompt string, so the displayed prompt emits an ANSI SGR sequence the
    // emulator renders as a red foreground. cmd echoes the literal `$E` text in
    // the command line; only the expanded prompt carries the real ESC bytes.
    const std::string c = model.create(shell, "", {});
    expectRunning(c);
    model.send(c, "prompt $E[31mRED$E[0m$G\r\n");
    model.send(c, "\r\n");  // empty command forces the new prompt to be displayed
    const bool sawRed = waitUntil([&] {
        const auto* session = model.find(c);
        return session != nullptr && hasRedForegroundCell(*session);
    }, 15000);
    if (!sawRed) {
        const auto* session = model.find(c);
        std::cerr << "[terminal_integration] no red-foreground cell in session " << c
                  << "; buffer=[" << (session != nullptr ? session->render(65536) : std::string()) << "]\n";
    }
    assert(sawRed);
    std::cerr << "[phase] SGR color rendered\n";

    // --- 6.1: cursor positioning. A prompt of `<ESC>[5;10H>` moves the cursor
    // to display row 5 (0-based 4); the emulator's cursor tracks it. The prompt
    // is re-displayed after the empty command, so the assertion is stable.
    model.send(c, "prompt $E[5;10H$G\r\n");
    model.send(c, "\r\n");
    const bool cursorMoved = waitUntil([&] {
        const auto* session = model.find(c);
        return session != nullptr && session->emulator().cursorRow() == 4;
    }, 15000);
    if (!cursorMoved) {
        const auto* session = model.find(c);
        std::cerr << "[terminal_integration] cursor did not reach row 4 in " << c
                  << "; cursorRow=" << (session != nullptr ? session->emulator().cursorRow() : -1)
                  << " buffer=[" << (session != nullptr ? session->render(65536) : std::string()) << "]\n";
    }
    assert(cursorMoved);
    std::cerr << "[phase] cursor positioned\n";

    // --- 6.2: PTY resize propagates to the shell. Resizing the session's
    // ConPTY to 100x30 must be reflected in what cmd's `mode con` reports.
    model.find(c)->resize(100, 30);
    model.send(c, "mode con\r\n");
    const bool resized = waitUntil([&] {
        const auto* session = model.find(c);
        if (session == nullptr) return false;
        const auto dims = modeDimensions(session->render(65536));
        return dims.has_value() && dims->first == 30 && dims->second == 100;
    }, 15000);
    if (!resized) {
        const auto* session = model.find(c);
        std::cerr << "[terminal_integration] shell did not report 100x30 after resize; buffer=["
                  << (session != nullptr ? session->render(65536) : std::string()) << "]\n";
    }
    assert(resized);
    std::cerr << "[phase] PTY resized\n";

    // --- interrupt: a long-running foreground command in A is stopped by
    // Ctrl+C, and A accepts further input afterwards. ping is used because it
    // stays in the foreground for ~19s; its presence is detected via the
    // process tree since the "Pinging ..." text is localized on non-English
    // systems.
    model.send(a, "ping -n 20 127.0.0.1\r\n");
    assert(waitUntil([&] { return hasDescendantExecutable(selfPid, L"ping.exe"); }, 15000));
    model.interrupt(a);
    assert(waitUntil([&] { return !hasDescendantExecutable(selfPid, L"ping.exe"); }, 15000));
    model.send(a, "echo AFTER_INTERRUPT_7\r\n");
    assert(waitUntil([&] {
        return model.find(a)->render(65536).find("AFTER_INTERRUPT_7") != std::string::npos;
    }, 15000));
    std::cerr << "[phase] interrupted\n";

    // --- restart: A relaunches under a new launch generation and runs again ---
    model.restart(a);
    assert(waitUntil([&] {
        const auto* session = model.find(a);
        return session != nullptr && session->state() == ProcessLifecycleState::Running;
    }, 15000));
    std::cerr << "[phase] restarted\n";

    // --- teardown: closeAll() (the workspace-switch / project-close path)
    // kills every session's whole process tree ---
    model.closeAll();
    assert(waitUntil([&] { return descendantProcesses(selfPid).empty(); }, 15000));
    assert(model.sessionIds().empty());
    std::cerr << "[phase] all torn down\n";

    return 0;
#endif
}
