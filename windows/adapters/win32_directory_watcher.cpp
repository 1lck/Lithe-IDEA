#include "win32_directory_watcher.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace lithe::windows {

struct Win32DirectoryChangeSource::Impl {
    std::atomic<bool> stopping{false};
    std::thread worker;
    std::string root;
    ChangeHandler handler;
#ifdef _WIN32
    HANDLE stopEvent = nullptr;
#endif
};

Win32DirectoryChangeSource::Win32DirectoryChangeSource()
    : impl_(std::make_unique<Impl>()) {}

Win32DirectoryChangeSource::~Win32DirectoryChangeSource() {
    stop();
}

void Win32DirectoryChangeSource::start(const std::string& root, ChangeHandler handler) {
    stop();
    impl_->stopping = false;
    impl_->root = root;
    impl_->handler = std::move(handler);
#ifdef _WIN32
    impl_->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
#endif
    impl_->worker = std::thread([state = impl_.get()] {
#ifdef _WIN32
        const auto utf8ToWide = [](const std::string& value) {
            const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
            std::wstring result(static_cast<std::size_t>(length), L'\0');
            if (length > 0) MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), length);
            return result;
        };
        const auto wideToUtf8 = [](const wchar_t* value, int length) {
            const int bytes = WideCharToMultiByte(CP_UTF8, 0, value, length, nullptr, 0, nullptr, nullptr);
            std::string result(static_cast<std::size_t>(bytes), '\0');
            if (bytes > 0) WideCharToMultiByte(CP_UTF8, 0, value, length, result.data(), bytes, nullptr, nullptr);
            return result;
        };
        const auto root = utf8ToWide(state->root);
        const HANDLE directory = CreateFileW(
            root.c_str(), FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
        if (directory == INVALID_HANDLE_VALUE) return;
        std::vector<std::byte> buffer(64 * 1024);
        while (!state->stopping) {
            DWORD bytes = 0;
            if (!ReadDirectoryChangesW(directory, buffer.data(), static_cast<DWORD>(buffer.size()), TRUE,
                                       FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                                           FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
                                       &bytes, nullptr, nullptr)) {
                break;
            }
            if (bytes == 0) continue;
            std::vector<std::string> paths;
            auto* record = reinterpret_cast<FILE_NOTIFY_INFORMATION*>(buffer.data());
            while (record != nullptr) {
                paths.push_back(wideToUtf8(record->FileName, static_cast<int>(record->FileNameLength / sizeof(wchar_t))));
                if (record->NextEntryOffset == 0) break;
                record = reinterpret_cast<FILE_NOTIFY_INFORMATION*>(reinterpret_cast<std::byte*>(record) + record->NextEntryOffset);
            }
            if (!paths.empty() && state->handler) state->handler(paths);
        }
        CloseHandle(directory);
#else
        // The non-Windows build keeps the adapter linkable for contract tests.
        // Real change notifications are supplied by ReadDirectoryChangesW.
        while (!state->stopping) std::this_thread::sleep_for(std::chrono::milliseconds(25));
#endif
    });
}

void Win32DirectoryChangeSource::stop() {
    if (!impl_ || !impl_->worker.joinable()) return;
    impl_->stopping = true;
#ifdef _WIN32
    if (impl_->stopEvent) SetEvent(impl_->stopEvent);
    // ReadDirectoryChangesW is synchronous; cancelling the worker I/O lets
    // shutdown complete without leaking a directory handle.
    CancelSynchronousIo(impl_->worker.native_handle());
#endif
    impl_->worker.join();
#ifdef _WIN32
    if (impl_->stopEvent) {
        CloseHandle(impl_->stopEvent);
        impl_->stopEvent = nullptr;
    }
#endif
}

} // namespace lithe::windows
