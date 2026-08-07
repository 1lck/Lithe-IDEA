#include "win32_process_session.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <iterator>
#include <map>
#include <mutex>
#include <limits>
#include <optional>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace lithe::windows {
namespace {

#ifdef _WIN32

std::string winError(DWORD code = GetLastError()) {
    if (code == ERROR_SUCCESS) return {};
    char* buffer = nullptr;
    const auto length = FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<LPSTR>(&buffer), 0, nullptr);
    std::string message = length > 0 && buffer != nullptr
        ? std::string(buffer, length)
        : "Win32 error " + std::to_string(code);
    if (buffer != nullptr) LocalFree(buffer);
    while (!message.empty() && (message.back() == '\r' || message.back() == '\n')) {
        message.pop_back();
    }
    return message;
}

std::optional<std::wstring> wide(const std::string& value) {
    if (value.empty()) return std::wstring{};
    const int length = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        nullptr, 0);
    if (length <= 0) return std::nullopt;
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(), length) != length) {
        return std::nullopt;
    }
    return result;
}

std::wstring withLongPathPrefix(std::wstring path) {
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.size() < MAX_PATH || path.rfind(L"\\\\?\\", 0) == 0) return path;
    if (path.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC" + path.substr(1);
    return L"\\\\?\\" + path;
}

std::wstring quote(const std::wstring& text) {
    std::wstring result = L"\"";
    unsigned backslashes = 0;
    for (const wchar_t character : text) {
        if (character == L'\\') {
            ++backslashes;
            continue;
        }
        if (character == L'\"') result.append(backslashes * 2 + 1, L'\\');
        else result.append(backslashes, L'\\');
        result.push_back(character);
        backslashes = 0;
    }
    result.append(backslashes * 2, L'\\');
    result += L'\"';
    return result;
}

std::optional<std::wstring> commandLine(const ProcessRequest& request) {
    const auto executable = wide(request.executablePath);
    if (!executable) return std::nullopt;
    const auto executablePath = withLongPathPrefix(*executable);
    std::wstring command = quote(executablePath);
    for (const auto& argument : request.arguments) {
        const auto value = wide(argument);
        if (!value) return std::nullopt;
        command += L' ';
        command += quote(*value);
    }
    const auto extension = std::filesystem::path(executablePath).extension().wstring();
    std::wstring normalizedExtension = extension;
    std::transform(normalizedExtension.begin(), normalizedExtension.end(),
                   normalizedExtension.begin(), [](wchar_t character) {
                       return static_cast<wchar_t>(std::towlower(character));
                   });
    if (normalizedExtension != L".cmd" && normalizedExtension != L".bat") return command;

    wchar_t comSpec[32768];
    const auto length = GetEnvironmentVariableW(L"ComSpec", comSpec,
                                                  static_cast<DWORD>(std::size(comSpec)));
    const std::wstring interpreter = length > 0 && length < std::size(comSpec)
        ? std::wstring(comSpec, length)
        : L"cmd.exe";
    return quote(interpreter) + L" /d /s /c \"" + command + L"\"";
}

struct EnvironmentBlock {
    std::vector<wchar_t> value;
};

std::optional<EnvironmentBlock> environmentBlock(
    const std::map<std::string, std::string>& overrides) {
    if (overrides.empty()) return EnvironmentBlock{};

    struct Entry {
        std::wstring key;
        std::wstring value;
    };
    std::vector<Entry> entries;

    LPWCH raw = GetEnvironmentStringsW();
    if (raw != nullptr) {
        for (const wchar_t* cursor = raw; *cursor != L'\0';) {
            std::wstring entry(cursor);
            cursor += entry.size() + 1;
            auto separator = entry.find(L'=');
            if (separator == 0) separator = entry.find(L'=', 1);
            if (separator == std::wstring::npos) continue;
            entries.push_back({entry.substr(0, separator), entry.substr(separator + 1)});
        }
        FreeEnvironmentStringsW(raw);
    }

    for (const auto& [keyUtf8, valueUtf8] : overrides) {
        const auto key = wide(keyUtf8);
        const auto value = wide(valueUtf8);
        if (!key || !value) return std::nullopt;
        auto existing = std::find_if(entries.begin(), entries.end(), [&](const Entry& entry) {
            return _wcsicmp(entry.key.c_str(), key->c_str()) == 0;
        });
        if (existing == entries.end()) entries.push_back({*key, *value});
        else existing->value = *value;
    }
    std::sort(entries.begin(), entries.end(), [](const Entry& left, const Entry& right) {
        return _wcsicmp(left.key.c_str(), right.key.c_str()) < 0;
    });

    EnvironmentBlock block;
    for (const auto& entry : entries) {
        block.value.insert(block.value.end(), entry.key.begin(), entry.key.end());
        block.value.push_back(L'=');
        block.value.insert(block.value.end(), entry.value.begin(), entry.value.end());
        block.value.push_back(L'\0');
    }
    block.value.push_back(L'\0');
    return block;
}

class IncrementalUtf8Decoder final {
public:
    std::string feed(const char* data, std::size_t length) {
        pending_.append(data, length);
        std::string result;
        std::size_t index = 0;
        while (index < pending_.size()) {
            const auto first = static_cast<unsigned char>(pending_[index]);
            std::size_t expected = 0;
            if (first <= 0x7f) expected = 1;
            else if (first >= 0xc2 && first <= 0xdf) expected = 2;
            else if (first >= 0xe0 && first <= 0xef) expected = 3;
            else if (first >= 0xf0 && first <= 0xf4) expected = 4;
            else {
                result += "\xef\xbf\xbd";
                ++index;
                continue;
            }
            if (pending_.size() - index < expected) break;
            bool valid = true;
            for (std::size_t offset = 1; offset < expected; ++offset) {
                const auto byte = static_cast<unsigned char>(pending_[index + offset]);
                if ((byte & 0xc0) != 0x80) valid = false;
            }
            if (valid && expected == 3) {
                const auto second = static_cast<unsigned char>(pending_[index + 1]);
                if ((first == 0xe0 && second < 0xa0) ||
                    (first == 0xed && second >= 0xa0)) valid = false;
            }
            if (valid && expected == 4) {
                const auto second = static_cast<unsigned char>(pending_[index + 1]);
                if ((first == 0xf0 && second < 0x90) ||
                    (first == 0xf4 && second >= 0x90)) valid = false;
            }
            if (!valid) {
                result += "\xef\xbf\xbd";
                ++index;
                continue;
            }
            result.append(pending_, index, expected);
            index += expected;
        }
        pending_.erase(0, index);
        return result;
    }

    std::string finish() {
        if (pending_.empty()) return {};
        pending_.clear();
        return "\xef\xbf\xbd";
    }

private:
    std::string pending_;
};

bool writeAll(HANDLE handle, std::string_view value, std::string& error) {
    std::size_t offset = 0;
    while (offset < value.size()) {
        const auto remaining = std::min<std::size_t>(
            value.size() - offset, std::numeric_limits<DWORD>::max());
        DWORD written = 0;
        if (!WriteFile(handle, value.data() + offset, static_cast<DWORD>(remaining),
                       &written, nullptr)) {
            error = "Process input write failed: " + winError();
            return false;
        }
        if (written == 0) {
            error = "Process input write failed: no bytes were written";
            return false;
        }
        offset += written;
    }
    return true;
}

#endif

} // namespace

struct Win32ProcessSession::Impl {
    mutable std::mutex mutex;
    std::mutex lifecycleMutex;
    std::mutex inputWriteMutex;
    std::atomic<bool> running{false};
    std::atomic<bool> stopping{false};
    std::thread worker;
    OutputHandler output;
    ErrorHandler error;
    LifecycleHandler lifecycle;
#ifdef _WIN32
    HANDLE process = nullptr;
    HANDLE job = nullptr;
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

void Win32ProcessSession::setErrorHandler(ErrorHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->error = std::move(handler);
}

void Win32ProcessSession::setLifecycleHandler(LifecycleHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->lifecycle = std::move(handler);
}

bool Win32ProcessSession::isRunning() const {
    return impl_->running.load(std::memory_order_acquire);
}

void Win32ProcessSession::start(const ProcessRequest& request) {
    std::lock_guard lifecycleLock(impl_->lifecycleMutex);
    stopImpl();
    impl_->stopping.store(false, std::memory_order_release);
    const auto operationID = request.operationID;
    const auto emit = [state = impl_.get(), operationID](
                          ProcessLifecycleState lifecycleState,
                          std::optional<std::int32_t> exitCode = std::nullopt,
                          std::string message = {}) {
        LifecycleHandler handler;
        {
            std::lock_guard lock(state->mutex);
            handler = state->lifecycle;
        }
        if (handler) {
            handler(ProcessLifecycleEvent{
                operationID, lifecycleState, exitCode, std::move(message)});
        }
    };
    emit(ProcessLifecycleState::Starting);

#ifndef _WIN32
    (void)request;
    emit(ProcessLifecycleState::Failed, 1,
         "Win32 process adapter requires Windows");
    return;
#else
    impl_->worker = std::thread([state = impl_.get(), request, emit] {
        SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        HANDLE childInput = nullptr;
        HANDLE parentInput = nullptr;
        HANDLE parentOutput = nullptr;
        HANDLE childOutput = nullptr;
        HANDLE parentError = nullptr;
        HANDLE childError = nullptr;
        HANDLE job = nullptr;
        auto close = [](HANDLE& handle) {
            if (handle != nullptr) {
                CloseHandle(handle);
                handle = nullptr;
            }
        };
        auto fail = [&](std::string message) {
            close(childInput);
            close(parentInput);
            close(parentOutput);
            close(childOutput);
            close(parentError);
            close(childError);
            close(job);
            emit(ProcessLifecycleState::Failed, 1, std::move(message));
        };

        if (!CreatePipe(&childInput, &parentInput, &security, 0) ||
            !CreatePipe(&parentOutput, &childOutput, &security, 0) ||
            !CreatePipe(&parentError, &childError, &security, 0)) {
            fail("Could not create process pipes: " + winError());
            return;
        }
        SetHandleInformation(parentInput, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(parentOutput, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(parentError, HANDLE_FLAG_INHERIT, 0);

        const auto command = commandLine(request);
        auto directory = request.workingDirectory
            ? wide(*request.workingDirectory)
            : std::optional<std::wstring>(std::wstring{});
        const auto environment = environmentBlock(request.environment);
        if (!command || !directory || !environment) {
            fail("Process request contains invalid UTF-8");
            return;
        }
        if (!directory->empty()) *directory = withLongPathPrefix(*directory);

        job = CreateJobObjectW(nullptr, nullptr);
        if (job == nullptr) {
            fail("Could not create process job: " + winError());
            return;
        }
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(
                job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
            fail("Could not configure process job: " + winError());
            return;
        }

        STARTUPINFOW startup{sizeof(STARTUPINFOW)};
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = childInput;
        startup.hStdOutput = childOutput;
        startup.hStdError = childError;
        PROCESS_INFORMATION processInfo{};
        auto mutableCommand = *command;
        const DWORD creationFlags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT |
            CREATE_SUSPENDED;
        if (!CreateProcessW(
                nullptr, mutableCommand.data(), nullptr, nullptr, TRUE,
                creationFlags,
                environment->value.empty() ? nullptr : environment->value.data(),
                directory->empty() ? nullptr : directory->c_str(),
                &startup, &processInfo)) {
            fail("Could not start process: " + winError());
            return;
        }
        close(childInput);
        close(childOutput);
        close(childError);

        if (!AssignProcessToJobObject(job, processInfo.hProcess)) {
            const auto message = winError();
            TerminateProcess(processInfo.hProcess, 1);
            WaitForSingleObject(processInfo.hProcess, INFINITE);
            close(processInfo.hThread);
            close(job);
            close(processInfo.hProcess);
            close(parentInput);
            close(parentOutput);
            close(parentError);
            emit(ProcessLifecycleState::Failed, 1,
                 "Could not attach process to job: " + message);
            return;
        }

        const auto resumeResult = ResumeThread(processInfo.hThread);
        if (resumeResult == static_cast<DWORD>(-1)) {
            const auto message = winError();
            if (!TerminateJobObject(job, 1)) TerminateProcess(processInfo.hProcess, 1);
            WaitForSingleObject(processInfo.hProcess, INFINITE);
            close(processInfo.hThread);
            close(job);
            close(processInfo.hProcess);
            close(parentInput);
            close(parentOutput);
            close(parentError);
            emit(ProcessLifecycleState::Failed, 1,
                 "Could not resume process: " + message);
            return;
        }
        close(processInfo.hThread);

        {
            std::lock_guard lock(state->mutex);
            state->process = processInfo.hProcess;
            state->job = job;
            state->input = parentInput;
            parentInput = nullptr;
        }
        state->running.store(true, std::memory_order_release);
        if (state->stopping.load(std::memory_order_acquire)) {
            std::lock_guard lock(state->mutex);
            if (state->job != nullptr) TerminateJobObject(state->job, 130);
        }

        auto writeInput = [state](std::string_view value) {
            if (value.empty()) return;
            std::lock_guard writeLock(state->inputWriteMutex);
            HANDLE duplicate = nullptr;
            std::string errorMessage;
            {
                std::lock_guard lock(state->mutex);
                if (state->input == nullptr) return;
                if (!DuplicateHandle(GetCurrentProcess(), state->input,
                                     GetCurrentProcess(), &duplicate, 0, FALSE,
                                     DUPLICATE_SAME_ACCESS)) {
                    errorMessage = "Could not duplicate process input handle: " + winError();
                }
            }
            if (duplicate != nullptr) {
                writeAll(duplicate, value, errorMessage);
                CloseHandle(duplicate);
            }
            if (!errorMessage.empty()) {
                ErrorHandler handler;
                { std::lock_guard lock(state->mutex); handler = state->error; }
                if (handler) handler(errorMessage);
            }
        };
        if (request.standardInput) writeInput(*request.standardInput);
        if (!request.keepsStandardInputOpen) {
            HANDLE input = nullptr;
            {
                std::lock_guard lock(state->mutex);
                input = state->input;
                state->input = nullptr;
            }
            close(input);
        }
        emit(ProcessLifecycleState::Running);

        auto readPipe = [state](HANDLE pipe, bool isError) {
            IncrementalUtf8Decoder decoder;
            char buffer[4096];
            for (;;) {
                DWORD bytes = 0;
                if (!ReadFile(pipe, buffer, sizeof(buffer), &bytes, nullptr)) {
                    const auto error = GetLastError();
                    if (error != ERROR_BROKEN_PIPE && error != ERROR_OPERATION_ABORTED) {
                        ErrorHandler handler;
                        {
                            std::lock_guard lock(state->mutex);
                            handler = state->error;
                        }
                        if (handler) handler("Process pipe read failed: " + winError(error));
                    }
                    break;
                }
                if (bytes == 0) break;
                auto text = decoder.feed(buffer, bytes);
                if (text.empty()) continue;
                if (isError) {
                    ErrorHandler handler;
                    { std::lock_guard lock(state->mutex); handler = state->error; }
                    if (handler) handler(text);
                } else {
                    OutputHandler handler;
                    { std::lock_guard lock(state->mutex); handler = state->output; }
                    if (handler) handler(text);
                }
            }
            auto tail = decoder.finish();
            if (!tail.empty()) {
                if (isError) {
                    ErrorHandler handler;
                    { std::lock_guard lock(state->mutex); handler = state->error; }
                    if (handler) handler(tail);
                } else {
                    OutputHandler handler;
                    { std::lock_guard lock(state->mutex); handler = state->output; }
                    if (handler) handler(tail);
                }
            }
            CloseHandle(pipe);
        };
        std::thread stdoutReader([&readPipe, parentOutput] {
            readPipe(parentOutput, false);
        });
        std::thread stderrReader([&readPipe, parentError] {
            readPipe(parentError, true);
        });

        bool stoppingEventSent = false;
        bool timedOut = false;
        const auto started = std::chrono::steady_clock::now();
        for (;;) {
            if (WaitForSingleObject(processInfo.hProcess, 25) == WAIT_OBJECT_0) break;
            if (state->stopping.load(std::memory_order_acquire)) {
                if (!stoppingEventSent) {
                    stoppingEventSent = true;
                    emit(ProcessLifecycleState::Stopping, 130, "Process stopped");
                }
                TerminateJobObject(job, 130);
                break;
            }
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started).count();
            if (request.timeoutMilliseconds && *request.timeoutMilliseconds > 0 &&
                elapsed >= 0 && static_cast<std::uint64_t>(elapsed) >=
                    *request.timeoutMilliseconds) {
                timedOut = true;
                stoppingEventSent = true;
                state->stopping.store(true, std::memory_order_release);
                emit(ProcessLifecycleState::Stopping, 124, "Process timed out");
                TerminateJobObject(job, 124);
                break;
            }
        }
        WaitForSingleObject(processInfo.hProcess, INFINITE);
        DWORD exitCode = 1;
        GetExitCodeProcess(processInfo.hProcess, &exitCode);
        // A child can inherit the redirected streams and keep the reader
        // threads blocked after the root process exits.  Tear down the whole
        // job before joining those readers so a process tree cannot leak a
        // pipe lifetime past this session.
        TerminateJobObject(job, exitCode);
        stdoutReader.join();
        stderrReader.join();

        HANDLE input = nullptr;
        HANDLE process = nullptr;
        HANDLE storedJob = nullptr;
        {
            std::lock_guard lock(state->mutex);
            input = state->input;
            state->input = nullptr;
            process = state->process;
            state->process = nullptr;
            storedJob = state->job;
            state->job = nullptr;
        }
        close(input);
        close(process);
        close(storedJob);
        state->running.store(false, std::memory_order_release);
        if (!stoppingEventSent && state->stopping.load(std::memory_order_acquire)) {
            emit(ProcessLifecycleState::Stopping, 130, "Process stopped");
        }
        emit(ProcessLifecycleState::Finished, static_cast<std::int32_t>(exitCode),
             timedOut ? "Process timed out" : "");
    });
#endif
}

void Win32ProcessSession::send(const std::string& input) {
#ifdef _WIN32
    if (input.empty()) return;
    std::lock_guard writeLock(impl_->inputWriteMutex);
    HANDLE duplicate = nullptr;
    std::string errorMessage;
    {
        std::lock_guard lock(impl_->mutex);
        if (impl_->input == nullptr) return;
        if (!DuplicateHandle(GetCurrentProcess(), impl_->input,
                             GetCurrentProcess(), &duplicate, 0, FALSE,
                             DUPLICATE_SAME_ACCESS)) {
            errorMessage = "Could not duplicate process input handle: " + winError();
        }
    }
    if (duplicate != nullptr) {
        writeAll(duplicate, input, errorMessage);
        CloseHandle(duplicate);
    }
    if (!errorMessage.empty()) {
        ErrorHandler handler;
        { std::lock_guard lock(impl_->mutex); handler = impl_->error; }
        if (handler) handler(errorMessage);
    }
#else
    (void)input;
#endif
}

void Win32ProcessSession::closeInput() {
#ifdef _WIN32
    HANDLE input = nullptr;
    {
        std::lock_guard lock(impl_->mutex);
        input = impl_->input;
        impl_->input = nullptr;
    }
    if (input != nullptr) CloseHandle(input);
#endif
}

void Win32ProcessSession::stopImpl() {
    impl_->stopping.store(true, std::memory_order_release);
#ifdef _WIN32
    // Keep the job handle protected until termination is requested.  The
    // worker clears and closes the same handle after the process exits.
    {
        std::lock_guard lock(impl_->mutex);
        if (impl_->job != nullptr) TerminateJobObject(impl_->job, 130);
    }
#endif
    if (impl_->worker.joinable()) impl_->worker.join();
    impl_->running.store(false, std::memory_order_release);
}

void Win32ProcessSession::stop() {
    std::lock_guard lifecycleLock(impl_->lifecycleMutex);
    stopImpl();
}

} // namespace lithe::windows
