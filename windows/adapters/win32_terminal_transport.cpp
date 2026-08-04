#include "win32_terminal_transport.h"

#include <atomic>
#include <mutex>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#include <winconpty.h>
#endif

namespace lithe::windows {

#ifdef _WIN32
namespace {

std::wstring wide(const std::string& value) {
    const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    if (length > 0) MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), length);
    return result;
}

std::wstring quote(const std::string& value) {
    const auto text = wide(value);
    std::wstring result = L"\"";
    unsigned backslashes = 0;
    for (const wchar_t character : text) {
        if (character == L'\\') { ++backslashes; continue; }
        if (character == L'"') result.append(backslashes * 2 + 1, L'\\');
        else result.append(backslashes, L'\\');
        result.push_back(character);
        backslashes = 0;
    }
    result.append(backslashes * 2, L'\\');
    result += L'"';
    return result;
}

std::wstring commandLine(const ProcessRequest& request) {
    std::wstring result = quote(request.executablePath);
    for (const auto& argument : request.arguments) {
        result += L' ';
        result += quote(argument);
    }
    return result;
}

} // namespace
#endif

struct Win32TerminalTransport::Impl {
    std::mutex mutex;
    std::thread worker;
    std::atomic<bool> stopping{false};
    OutputHandler output;
    ExitHandler exit;
#ifdef _WIN32
    HPCON console = nullptr;
    HANDLE process = nullptr;
    HANDLE input = nullptr;
    HANDLE outputPipe = nullptr;
#endif
};

Win32TerminalTransport::Win32TerminalTransport()
    : impl_(std::make_unique<Impl>()) {}

Win32TerminalTransport::~Win32TerminalTransport() {
    stop();
}

void Win32TerminalTransport::setOutputHandler(OutputHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->output = std::move(handler);
}

void Win32TerminalTransport::setExitHandler(ExitHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->exit = std::move(handler);
}

void Win32TerminalTransport::start(const ProcessRequest& request) {
    stop();
    impl_->stopping = false;
#ifndef _WIN32
    (void)request;
    ExitHandler handler;
    { std::lock_guard lock(impl_->mutex); handler = impl_->exit; }
    if (handler) handler();
#else
    impl_->worker = std::thread([state = impl_.get(), request] {
        SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        HANDLE ptyInput = nullptr;
        HANDLE ptyOutput = nullptr;
        if (!CreatePipe(&ptyInput, &state->input, &security, 0) ||
            !CreatePipe(&state->outputPipe, &ptyOutput, &security, 0)) {
            return;
        }
        COORD size{120, 40};
        if (FAILED(CreatePseudoConsole(size, ptyInput, ptyOutput, 0, &state->console))) return;
        CloseHandle(ptyInput);
        CloseHandle(ptyOutput);
        SetHandleInformation(state->input, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(state->outputPipe, HANDLE_FLAG_INHERIT, 0);

        SIZE_T attributeBytes = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeBytes);
        auto* attributes = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(HeapAlloc(GetProcessHeap(), 0, attributeBytes));
        if (!attributes || !InitializeProcThreadAttributeList(attributes, 1, 0, &attributeBytes) ||
            !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                       state->console, sizeof(HPCON), nullptr, nullptr)) return;
        STARTUPINFOEXW startup{sizeof(STARTUPINFOEXW)};
        startup.lpAttributeList = attributes;
        PROCESS_INFORMATION processInfo{};
        auto command = commandLine(request);
        const auto directory = request.workingDirectory ? wide(*request.workingDirectory) : std::wstring{};
        if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                            EXTENDED_STARTUPINFO_PRESENT, nullptr,
                            directory.empty() ? nullptr : directory.c_str(),
                            &startup.StartupInfo, &processInfo)) {
            DeleteProcThreadAttributeList(attributes); HeapFree(GetProcessHeap(), 0, attributes); return;
        }
        CloseHandle(processInfo.hThread);
        state->process = processInfo.hProcess;
        if (state->stopping) TerminateProcess(state->process, 130);
        DeleteProcThreadAttributeList(attributes);
        HeapFree(GetProcessHeap(), 0, attributes);

        char buffer[4096];
        DWORD bytes = 0;
        while (!state->stopping && ReadFile(state->outputPipe, buffer, sizeof(buffer), &bytes, nullptr) && bytes > 0) {
            OutputHandler handler;
            { std::lock_guard lock(state->mutex); handler = state->output; }
            if (handler) handler(std::string(buffer, buffer + bytes));
        }
        WaitForSingleObject(state->process, INFINITE);
        CloseHandle(state->process);
        state->process = nullptr;
        CloseHandle(state->outputPipe); state->outputPipe = nullptr;
        ClosePseudoConsole(state->console); state->console = nullptr;
        CloseHandle(state->input); state->input = nullptr;
        ExitHandler handler;
        { std::lock_guard lock(state->mutex); handler = state->exit; }
        if (handler) handler();
    });
#endif
}

void Win32TerminalTransport::send(const std::string& input) {
#ifdef _WIN32
    std::lock_guard lock(impl_->mutex);
    if (impl_->input) {
        DWORD written = 0;
        WriteFile(impl_->input, input.data(), static_cast<DWORD>(input.size()), &written, nullptr);
    }
#else
    (void)input;
#endif
}

void Win32TerminalTransport::resize(int columns, int rows) {
#ifdef _WIN32
    std::lock_guard lock(impl_->mutex);
    if (impl_->console) ResizePseudoConsole(impl_->console, COORD{static_cast<SHORT>(columns), static_cast<SHORT>(rows)});
#else
    (void)columns; (void)rows;
#endif
}

void Win32TerminalTransport::stop() {
    if (!impl_->worker.joinable()) return;
    impl_->stopping = true;
#ifdef _WIN32
    if (impl_->process) TerminateProcess(impl_->process, 130);
    if (impl_->outputPipe) CancelSynchronousIo(impl_->worker.native_handle());
#endif
    impl_->worker.join();
}

} // namespace lithe::windows
