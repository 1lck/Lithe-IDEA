#include "win32_process_session.h"

#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#endif

namespace lithe::windows {
namespace {

#ifdef _WIN32
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
#endif

} // namespace

struct Win32ProcessSession::Impl {
    mutable std::mutex mutex;
    std::atomic<bool> running{false};
    std::atomic<bool> stopping{false};
    std::thread worker;
    OutputHandler output;
    LifecycleHandler lifecycle;
#ifdef _WIN32
    HANDLE process = nullptr;
    HANDLE input = nullptr;
#endif
};

Win32ProcessSession::Win32ProcessSession()
    : impl_(std::make_unique<Impl>()) {}

Win32ProcessSession::~Win32ProcessSession() {
    stop();
}

void Win32ProcessSession::setOutputHandler(OutputHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->output = std::move(handler);
}

void Win32ProcessSession::setLifecycleHandler(LifecycleHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->lifecycle = std::move(handler);
}

bool Win32ProcessSession::isRunning() const {
    return impl_->running.load();
}

void Win32ProcessSession::start(const ProcessRequest& request) {
    stop();
    impl_->stopping = false;
    const auto operationID = request.operationID;
    const auto emit = [state = impl_.get(), operationID](ProcessLifecycleState lifecycleState,
                                                      std::optional<std::int32_t> exitCode = std::nullopt,
                                                      std::string message = {}) {
        LifecycleHandler handler;
        {
            std::lock_guard lock(state->mutex);
            handler = state->lifecycle;
        }
        if (handler) handler(ProcessLifecycleEvent{operationID, lifecycleState, exitCode, std::move(message)});
    };
    emit(ProcessLifecycleState::Starting);
#ifndef _WIN32
    emit(ProcessLifecycleState::Failed, 1, "Win32 process adapter requires Windows");
    return;
#else
    impl_->worker = std::thread([state = impl_.get(), request, emit] {
        SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        HANDLE childInput = nullptr;
        HANDLE childOutput = nullptr;
        HANDLE childError = nullptr;
        HANDLE parentOutput = nullptr;
        HANDLE parentError = nullptr;
        if (!CreatePipe(&childInput, &state->input, &security, 0) ||
            !CreatePipe(&parentOutput, &childOutput, &security, 0) ||
            !CreatePipe(&parentError, &childError, &security, 0)) {
            emit(ProcessLifecycleState::Failed, 1, "Could not create process pipes");
            return;
        }
        SetHandleInformation(state->input, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(parentOutput, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(parentError, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOW startup{sizeof(STARTUPINFOW)};
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = childInput;
        startup.hStdOutput = childOutput;
        startup.hStdError = childError;
        PROCESS_INFORMATION processInfo{};
        auto command = commandLine(request);
        const auto directory = request.workingDirectory ? wide(*request.workingDirectory) : std::wstring{};
        if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                            nullptr, directory.empty() ? nullptr : directory.c_str(),
                            &startup, &processInfo)) {
            CloseHandle(childInput); CloseHandle(childOutput); CloseHandle(childError); CloseHandle(parentOutput); CloseHandle(parentError);
            emit(ProcessLifecycleState::Failed, 1, "Could not start process");
            return;
        }
        CloseHandle(processInfo.hThread);
        CloseHandle(childInput); CloseHandle(childOutput); CloseHandle(childError);
        state->process = processInfo.hProcess;
        if (state->stopping) TerminateProcess(state->process, 130);
        state->running = true;
        emit(ProcessLifecycleState::Running);

        std::thread reader([state, parentOutput, parentError] {
            char buffer[4096];
            DWORD bytes = 0;
            auto read = [state](HANDLE handle) {
                char buffer[4096];
                DWORD bytes = 0;
                while (ReadFile(handle, buffer, sizeof(buffer), &bytes, nullptr) && bytes > 0) {
                    OutputHandler handler;
                    { std::lock_guard lock(state->mutex); handler = state->output; }
                    if (handler) handler(std::string(buffer, buffer + bytes));
                }
                CloseHandle(handle);
            };
            std::thread errorReader([&read, parentError] { read(parentError); });
            read(parentOutput);
            errorReader.join();
        });

        DWORD exitCode = STILL_ACTIVE;
        const auto started = std::chrono::steady_clock::now();
        while (!state->stopping && exitCode == STILL_ACTIVE) {
            if (WaitForSingleObject(state->process, 25) == WAIT_OBJECT_0) break;
            if (request.timeoutMilliseconds &&
                std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count() >= *request.timeoutMilliseconds) {
                state->stopping = true;
                TerminateProcess(state->process, 124);
                emit(ProcessLifecycleState::Stopping, 124, "Process timed out");
                break;
            }
            GetExitCodeProcess(state->process, &exitCode);
        }
        if (state->stopping) TerminateProcess(state->process, 130);
        WaitForSingleObject(state->process, INFINITE);
        GetExitCodeProcess(state->process, &exitCode);
        reader.join();
        CloseHandle(state->process);
        state->process = nullptr;
        CloseHandle(state->input);
        state->input = nullptr;
        state->running = false;
        emit(state->stopping ? ProcessLifecycleState::Stopping : ProcessLifecycleState::Finished,
             static_cast<std::int32_t>(exitCode), state->stopping ? "Process stopped" : "");
    });
#endif
}

void Win32ProcessSession::send(const std::string& input) {
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

void Win32ProcessSession::stop() {
    if (impl_->worker.joinable()) {
        impl_->stopping = true;
#ifdef _WIN32
        if (impl_->process) TerminateProcess(impl_->process, 130);
#endif
        impl_->worker.join();
    }
}

} // namespace lithe::windows
