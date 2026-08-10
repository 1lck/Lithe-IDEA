#include "win32_terminal_transport.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cwctype>
#include <filesystem>
#include <iterator>
#include <map>
#include <limits>
#include <mutex>
#include <optional>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A000006
#endif
#include <windows.h>
#include <consoleapi.h>
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
    struct Entry { std::wstring key; std::wstring value; };
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
            error = "Terminal input write failed: " + winError();
            return false;
        }
        if (written == 0) {
            error = "Terminal input write failed: no bytes were written";
            return false;
        }
        offset += written;
    }
    return true;
}

#endif

} // namespace

struct Win32TerminalTransport::Impl {
    mutable std::mutex mutex;
    std::mutex lifecycleMutex;
    std::mutex inputWriteMutex;
    std::thread worker;
    std::atomic<bool> running{false};
    std::atomic<bool> stopping{false};
    std::atomic<bool> exited{false};
    OutputHandler output;
    ErrorHandler error;
    ExitHandler exit;
#ifdef _WIN32
    HPCON console = nullptr;
    HANDLE process = nullptr;
    HANDLE job = nullptr;
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

void Win32TerminalTransport::setErrorHandler(ErrorHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->error = std::move(handler);
}

void Win32TerminalTransport::setExitHandler(ExitHandler handler) {
    std::lock_guard lock(impl_->mutex);
    impl_->exit = std::move(handler);
}

void Win32TerminalTransport::start(const ProcessRequest& request) {
    std::lock_guard lifecycleLock(impl_->lifecycleMutex);
    stopImpl();
    impl_->stopping.store(false, std::memory_order_release);
    impl_->exited.store(false, std::memory_order_release);
    impl_->running.store(false, std::memory_order_release);
#ifndef _WIN32
    (void)request;
    impl_->running.store(false, std::memory_order_release);
    ErrorHandler error;
    ExitHandler exit;
    {
        std::lock_guard lock(impl_->mutex);
        error = impl_->error;
        exit = impl_->exit;
    }
    if (error) error("Win32 terminal adapter requires Windows");
    if (exit) exit();
#else
    impl_->worker = std::thread([state = impl_.get(), request] {
        auto reportError = [state](const std::string& message) {
            ErrorHandler handler;
            { std::lock_guard lock(state->mutex); handler = state->error; }
            if (handler) handler(message);
        };
        auto reportExit = [state] {
            if (state->exited.exchange(true, std::memory_order_acq_rel)) return;
            state->running.store(false, std::memory_order_release);
            ExitHandler handler;
            { std::lock_guard lock(state->mutex); handler = state->exit; }
            if (handler) handler();
        };
        auto close = [](HANDLE& handle) {
            if (handle != nullptr) {
                CloseHandle(handle);
                handle = nullptr;
            }
        };

        SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        HANDLE ptyInput = nullptr;
        HANDLE parentInput = nullptr;
        HANDLE parentOutput = nullptr;
        HANDLE ptyOutput = nullptr;
        HANDLE job = nullptr;
        if (!CreatePipe(&ptyInput, &parentInput, &security, 0) ||
            !CreatePipe(&parentOutput, &ptyOutput, &security, 0)) {
            close(ptyInput); close(parentInput); close(parentOutput); close(ptyOutput);
            reportError("Could not create ConPTY pipes: " + winError());
            reportExit();
            return;
        }
        SetHandleInformation(parentInput, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(parentOutput, HANDLE_FLAG_INHERIT, 0);

        COORD size{120, 40};
        HPCON console = nullptr;
        const auto ptyResult = CreatePseudoConsole(size, ptyInput, ptyOutput, 0, &console);
        close(ptyInput);
        close(ptyOutput);
        if (FAILED(ptyResult)) {
            close(parentInput); close(parentOutput);
            reportError("Could not create ConPTY: HRESULT " + std::to_string(ptyResult));
            reportExit();
            return;
        }

        SIZE_T attributeBytes = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeBytes);
        auto* attributes = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(
            HeapAlloc(GetProcessHeap(), 0, attributeBytes));
        bool attributesInitialized = false;
        auto destroyAttributes = [&] {
            if (attributes != nullptr) {
                if (attributesInitialized) DeleteProcThreadAttributeList(attributes);
                HeapFree(GetProcessHeap(), 0, attributes);
                attributes = nullptr;
                attributesInitialized = false;
            }
        };
        if (attributes == nullptr ||
            !(attributesInitialized = InitializeProcThreadAttributeList(
                  attributes, 1, 0, &attributeBytes)) ||
            !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                       console, sizeof(HPCON), nullptr, nullptr)) {
            const auto message = winError();
            destroyAttributes();
            ClosePseudoConsole(console);
            close(parentInput); close(parentOutput);
            reportError("Could not configure ConPTY process attributes: " + message);
            reportExit();
            return;
        }

        auto directory = request.workingDirectory
            ? wide(*request.workingDirectory)
            : std::optional<std::wstring>(std::wstring{});
        auto environment = environmentBlock(request.environment);
        const auto command = commandLine(request);
        if (!directory || !environment || !command) {
            destroyAttributes();
            ClosePseudoConsole(console);
            close(parentInput); close(parentOutput);
            reportError("Terminal request contains invalid UTF-8");
            reportExit();
            return;
        }
        if (!directory->empty()) *directory = withLongPathPrefix(*directory);

        job = CreateJobObjectW(nullptr, nullptr);
        if (job == nullptr) {
            const auto message = winError();
            ClosePseudoConsole(console);
            close(parentInput); close(parentOutput);
            reportError("Could not create terminal job: " + message);
            reportExit();
            return;
        }
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(
                job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
            const auto message = winError();
            close(job);
            ClosePseudoConsole(console);
            close(parentInput); close(parentOutput);
            reportError("Could not configure terminal job: " + message);
            reportExit();
            return;
        }
        STARTUPINFOEXW startup{sizeof(STARTUPINFOEXW)};
        startup.lpAttributeList = attributes;
        PROCESS_INFORMATION processInfo{};
        auto mutableCommand = *command;
        const DWORD flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
            CREATE_SUSPENDED;
        const BOOL created = CreateProcessW(
            nullptr, mutableCommand.data(), nullptr, nullptr, FALSE, flags,
            environment->value.empty() ? nullptr : environment->value.data(),
            directory->empty() ? nullptr : directory->c_str(),
            &startup.StartupInfo, &processInfo);
        const auto createError = GetLastError();
        destroyAttributes();
        if (!created) {
            close(job);
            ClosePseudoConsole(console);
            close(parentInput); close(parentOutput);
            reportError("Could not start terminal process: " + winError(createError));
            reportExit();
            return;
        }

        if (!AssignProcessToJobObject(job, processInfo.hProcess)) {
            const auto message = winError();
            if (!TerminateJobObject(job, 1)) TerminateProcess(processInfo.hProcess, 1);
            WaitForSingleObject(processInfo.hProcess, INFINITE);
            close(processInfo.hThread);
            close(job);
            close(processInfo.hProcess);
            ClosePseudoConsole(console);
            close(parentInput); close(parentOutput);
            reportError("Could not attach terminal process to job: " + message);
            reportExit();
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
            ClosePseudoConsole(console);
            close(parentInput); close(parentOutput);
            reportError("Could not resume terminal process: " + message);
            reportExit();
            return;
        }
        close(processInfo.hThread);
        {
            std::lock_guard lock(state->mutex);
            state->console = console;
            state->process = processInfo.hProcess;
            state->job = job;
            state->input = parentInput;
            state->outputPipe = parentOutput;
            parentInput = nullptr;
        }
        state->running.store(true, std::memory_order_release);
        if (state->stopping.load(std::memory_order_acquire)) TerminateJobObject(job, 130);

        const HANDLE outputPipe = parentOutput;
        parentOutput = nullptr;
        auto readOutput = [&, outputPipe] {
            IncrementalUtf8Decoder decoder;
            char buffer[4096];
            for (;;) {
                DWORD bytes = 0;
                if (!ReadFile(outputPipe, buffer, sizeof(buffer), &bytes, nullptr)) break;
                if (bytes == 0) break;
                auto text = decoder.feed(buffer, bytes);
                if (text.empty()) continue;
                OutputHandler handler;
                { std::lock_guard lock(state->mutex); handler = state->output; }
                if (handler) handler(text);
            }
            auto tail = decoder.finish();
            if (!tail.empty()) {
                OutputHandler handler;
                { std::lock_guard lock(state->mutex); handler = state->output; }
                if (handler) handler(tail);
            }
            CloseHandle(outputPipe);
        };
        std::thread reader(readOutput);
        WaitForSingleObject(processInfo.hProcess, INFINITE);
        // ConPTY output can remain open while a descendant still owns an
        // inherited endpoint.  Close the console before joining the reader;
        // stopImpl() uses the same detach-under-lock ownership rule, so the
        // console is closed exactly once even when stop races process exit.
        HPCON finishedConsole = nullptr;
        {
            std::lock_guard lock(state->mutex);
            finishedConsole = state->console;
            state->console = nullptr;
        }
        if (finishedConsole != nullptr) ClosePseudoConsole(finishedConsole);
        reader.join();

        HANDLE input = nullptr;
        HANDLE process = nullptr;
        HANDLE storedJob = nullptr;
        HPCON storedConsole = nullptr;
        {
            std::lock_guard lock(state->mutex);
            input = state->input; state->input = nullptr;
            process = state->process; state->process = nullptr;
            storedJob = state->job; state->job = nullptr;
            storedConsole = state->console; state->console = nullptr;
            state->outputPipe = nullptr;
        }
        close(input);
        close(process);
        close(storedJob);
        if (storedConsole != nullptr) ClosePseudoConsole(storedConsole);
        state->stopping.store(false, std::memory_order_release);
        reportExit();
    });
#endif
}

void Win32TerminalTransport::send(const std::string& input) {
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
            errorMessage = "Could not duplicate terminal input handle: " + winError();
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

bool Win32TerminalTransport::isRunning() const {
    return impl_->running.load(std::memory_order_acquire);
}

void Win32TerminalTransport::stopImpl() {
    impl_->stopping.store(true, std::memory_order_release);
#ifdef _WIN32
    HPCON console = nullptr;
    {
        std::lock_guard lock(impl_->mutex);
        // The worker clears and closes the job after the process exits. Keep
        // the lock while requesting termination so it cannot race that close.
        if (impl_->job != nullptr) TerminateJobObject(impl_->job, 130);
        console = impl_->console;
        impl_->console = nullptr;
    }
    if (console != nullptr) ClosePseudoConsole(console);
#endif
    if (impl_->worker.joinable()) impl_->worker.join();
    impl_->running.store(false, std::memory_order_release);
    impl_->stopping.store(false, std::memory_order_release);
}

void Win32TerminalTransport::stop() {
    std::lock_guard lifecycleLock(impl_->lifecycleMutex);
    stopImpl();
}

void Win32TerminalTransport::resize(int columns, int rows) {
#ifdef _WIN32
    if (columns <= 0 || rows <= 0) return;
    std::lock_guard lock(impl_->mutex);
    if (impl_->console != nullptr) {
        ResizePseudoConsole(impl_->console,
                            COORD{static_cast<SHORT>(columns), static_cast<SHORT>(rows)});
    }
#else
    (void)columns;
    (void)rows;
#endif
}

} // namespace lithe::windows
