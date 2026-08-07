#include "win32_directory_watcher.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <string>
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

std::optional<std::wstring> utf8ToWide(const std::string& value) {
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

std::string wideToUtf8(const wchar_t* value, int length) {
    if (length <= 0) return {};
    const int bytes = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value, length, nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string result(static_cast<std::size_t>(bytes), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length,
                            result.data(), bytes, nullptr, nullptr) != bytes) {
        return {};
    }
    std::replace(result.begin(), result.end(), '\\', '/');
    return result;
}

std::wstring withLongPathPrefix(std::wstring path) {
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.size() < MAX_PATH || path.rfind(L"\\\\?\\", 0) == 0) return path;
    if (path.rfind(L"\\\\", 0) == 0) {
        return L"\\\\?\\UNC" + path.substr(1);
    }
    return L"\\\\?\\" + path;
}

DirectoryChangeSource::ChangeKind changeKind(DWORD action) {
    switch (action) {
    case FILE_ACTION_ADDED: return DirectoryChangeSource::ChangeKind::Added;
    case FILE_ACTION_REMOVED: return DirectoryChangeSource::ChangeKind::Removed;
    case FILE_ACTION_RENAMED_OLD_NAME:
        return DirectoryChangeSource::ChangeKind::RenamedOldName;
    case FILE_ACTION_RENAMED_NEW_NAME:
        return DirectoryChangeSource::ChangeKind::RenamedNewName;
    case FILE_ACTION_MODIFIED:
    default:
        return DirectoryChangeSource::ChangeKind::Modified;
    }
}

#endif

bool isStructuralChange(DirectoryChangeSource::ChangeKind kind) {
    switch (kind) {
    case DirectoryChangeSource::ChangeKind::Added:
    case DirectoryChangeSource::ChangeKind::Removed:
    case DirectoryChangeSource::ChangeKind::RenamedOldName:
    case DirectoryChangeSource::ChangeKind::RenamedNewName:
    case DirectoryChangeSource::ChangeKind::RescanRequired:
        return true;
    case DirectoryChangeSource::ChangeKind::Modified:
        return false;
    }
    return false;
}

} // namespace

struct Win32DirectoryChangeSource::Impl {
    mutable std::mutex mutex;
    std::mutex lifecycleMutex;
    std::atomic<bool> stopping{false};
    std::thread worker;
    std::string root;
    ChangeHandler handler;
    ErrorHandler errorHandler;
#ifdef _WIN32
    HANDLE stopEvent = nullptr;
#endif
};

Win32DirectoryChangeSource::Win32DirectoryChangeSource()
    : impl_(std::make_unique<Impl>()) {}

Win32DirectoryChangeSource::~Win32DirectoryChangeSource() {
    stop();
}

void Win32DirectoryChangeSource::start(const std::string& root,
                                       ChangeHandler handler,
                                       ErrorHandler errorHandler) {
    std::lock_guard lifecycleLock(impl_->lifecycleMutex);
    stopImpl();
    {
        std::lock_guard lock(impl_->mutex);
        impl_->stopping.store(false, std::memory_order_release);
        impl_->root = root;
        impl_->handler = std::move(handler);
        impl_->errorHandler = std::move(errorHandler);
    }
    if (root.empty()) {
        ErrorHandler error;
        { std::lock_guard lock(impl_->mutex); error = impl_->errorHandler; }
        if (error) error("Directory watcher root is empty");
        return;
    }
#ifdef _WIN32
    const auto stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (stopEvent == nullptr) {
        ErrorHandler error;
        { std::lock_guard lock(impl_->mutex); error = impl_->errorHandler; }
        if (error) error("Could not create watcher stop event: " + winError());
        return;
    }
    {
        std::lock_guard lock(impl_->mutex);
        impl_->stopEvent = stopEvent;
    }
#endif
    impl_->worker = std::thread([state = impl_.get()] {
#ifdef _WIN32
        ErrorHandler reportError = [state](const std::string& message) {
            ErrorHandler handler;
            { std::lock_guard lock(state->mutex); handler = state->errorHandler; }
            if (handler) handler(message);
        };
        std::string rootValue;
        HANDLE stopEvent = nullptr;
        {
            std::lock_guard lock(state->mutex);
            rootValue = state->root;
            stopEvent = state->stopEvent;
        }
        const auto convertedRoot = utf8ToWide(rootValue);
        if (!convertedRoot) {
            reportError("Directory watcher root is not valid UTF-8");
            return;
        }
        const auto root = withLongPathPrefix(*convertedRoot);
        const HANDLE directory = CreateFileW(
            root.c_str(), FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, nullptr);
        if (directory == INVALID_HANDLE_VALUE) {
            reportError("Could not open directory for watching: " + winError());
            return;
        }

        std::vector<std::byte> buffer(64 * 1024);
        OVERLAPPED overlapped{};
        overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (overlapped.hEvent == nullptr) {
            reportError("Could not create watcher I/O event: " + winError());
            CloseHandle(directory);
            return;
        }
        std::map<std::string, DirectoryChangeSource::Change> pending;
        auto lastChange = std::chrono::steady_clock::now();
        bool hasPending = false;

        auto dispatch = [&] {
            if (!hasPending) return;
            std::vector<DirectoryChangeSource::Change> changes;
            changes.reserve(pending.size());
            for (const auto& [path, change] : pending) changes.push_back(change);
            pending.clear();
            hasPending = false;
            ChangeHandler handler;
            { std::lock_guard lock(state->mutex); handler = state->handler; }
            if (handler && !changes.empty()) handler(changes);
        };
        auto addChange = [&](DirectoryChangeSource::Change change) {
            if (change.path.empty()) return;
            const auto existing = pending.find(change.path);
            if (existing == pending.end() ||
                (existing->second.kind != DirectoryChangeSource::ChangeKind::RescanRequired &&
                 (isStructuralChange(change.kind) ||
                  !isStructuralChange(existing->second.kind)))) {
                pending[change.path] = std::move(change);
            }
            hasPending = true;
            lastChange = std::chrono::steady_clock::now();
        };
        auto requireRescan = [&](const std::string& message) {
            pending.clear();
            addChange({".", DirectoryChangeSource::ChangeKind::RescanRequired});
            reportError(message);
        };
        auto issueRead = [&]() -> bool {
            for (;;) {
                ResetEvent(overlapped.hEvent);
                if (ReadDirectoryChangesW(
                        directory, buffer.data(), static_cast<DWORD>(buffer.size()), TRUE,
                        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                            FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
                        nullptr, &overlapped, nullptr)) {
                    return true;
                }
                const auto error = GetLastError();
                if (error == ERROR_IO_PENDING) return true;
                if (error == ERROR_NOTIFY_ENUM_DIR) {
                    requireRescan(
                        "Directory watcher buffer overflow; a full rescan is required");
                    continue;
                }
                if (error != ERROR_OPERATION_ABORTED) {
                    reportError("Could not arm directory watcher: " + winError(error));
                }
                return false;
            }
        };
        auto cancelRead = [&] {
            CancelIoEx(directory, &overlapped);
            WaitForSingleObject(overlapped.hEvent, INFINITE);
        };

        if (!issueRead()) {
            CloseHandle(overlapped.hEvent);
            CloseHandle(directory);
            return;
        }
        HANDLE waitHandles[] = {stopEvent, overlapped.hEvent};
        for (;;) {
            DWORD timeout = INFINITE;
            if (hasPending) {
                const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - lastChange).count();
                timeout = elapsed >= 350 ? 0 : static_cast<DWORD>(350 - elapsed);
            }
            const auto result = WaitForMultipleObjects(2, waitHandles, FALSE, timeout);
            if (result == WAIT_OBJECT_0) {
                cancelRead();
                break;
            }
            if (result == WAIT_TIMEOUT) {
                dispatch();
                continue;
            }
            if (result != WAIT_OBJECT_0 + 1) {
                reportError("Directory watcher wait failed: " + winError());
                cancelRead();
                break;
            }

            DWORD bytes = 0;
            if (!GetOverlappedResult(directory, &overlapped, &bytes, FALSE)) {
                const auto error = GetLastError();
                if (error == ERROR_OPERATION_ABORTED) break;
                if (error == ERROR_NOTIFY_ENUM_DIR) {
                    requireRescan(
                        "Directory watcher buffer overflow; a full rescan is required");
                } else {
                    reportError("Directory watcher read failed: " + winError(error));
                    break;
                }
            } else if (bytes > 0) {
                constexpr auto recordHeaderSize = offsetof(FILE_NOTIFY_INFORMATION, FileName);
                const auto available = static_cast<std::size_t>(bytes);
                std::size_t offset = 0;
                bool malformed = false;
                while (offset < available) {
                    if (available - offset < recordHeaderSize) {
                        malformed = true;
                        break;
                    }
                    auto* record = reinterpret_cast<FILE_NOTIFY_INFORMATION*>(
                        buffer.data() + offset);
                    const auto fileNameBytes = static_cast<std::size_t>(record->FileNameLength);
                    if (fileNameBytes % sizeof(wchar_t) != 0 ||
                        fileNameBytes > available - offset - recordHeaderSize) {
                        malformed = true;
                        break;
                    }
                    const auto recordSize = recordHeaderSize + fileNameBytes;
                    const auto nextOffset = static_cast<std::size_t>(record->NextEntryOffset);
                    if (nextOffset != 0 &&
                        (nextOffset < recordSize || nextOffset > available - offset)) {
                        malformed = true;
                        break;
                    }
                    const auto path = wideToUtf8(
                        record->FileName,
                        static_cast<int>(fileNameBytes / sizeof(wchar_t)));
                    addChange({path, changeKind(record->Action)});
                    if (nextOffset == 0) break;
                    offset += nextOffset;
                }
                if (malformed) {
                    requireRescan(
                        "Directory watcher returned a malformed notification; a full rescan is required");
                }
            }
            if (!issueRead()) break;
        }
        dispatch();
        CloseHandle(overlapped.hEvent);
        CloseHandle(directory);
#else
        while (!state->stopping.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
#endif
    });
}

void Win32DirectoryChangeSource::stopImpl() {
    impl_->stopping.store(true, std::memory_order_release);
#ifdef _WIN32
    HANDLE stopEvent = nullptr;
    {
        std::lock_guard lock(impl_->mutex);
        stopEvent = impl_->stopEvent;
    }
    if (stopEvent != nullptr) SetEvent(stopEvent);
#endif
    if (impl_->worker.joinable()) impl_->worker.join();
#ifdef _WIN32
    std::lock_guard lock(impl_->mutex);
    if (impl_->stopEvent != nullptr) {
        CloseHandle(impl_->stopEvent);
        impl_->stopEvent = nullptr;
    }
#endif
}

void Win32DirectoryChangeSource::stop() {
    std::lock_guard lifecycleLock(impl_->lifecycleMutex);
    stopImpl();
}

} // namespace lithe::windows
