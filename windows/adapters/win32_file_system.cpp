#include "win32_file_system.h"

#include <filesystem>
#include <fstream>
#include <random>
#include <sstream>

#ifdef _WIN32
#include <windows.h>
#endif

namespace lithe::windows {
namespace {

#ifdef _WIN32
std::wstring wide(const std::string& value) {
    if (value.empty()) return {};
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           value.data(), static_cast<int>(value.size()),
                                           nullptr, 0);
    if (length <= 0) return {};
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                        value.data(), static_cast<int>(value.size()),
                        result.data(), length);
    return result;
}

std::string winError() {
    return "Win32 error " + std::to_string(GetLastError());
}
#endif

std::string ioError(const std::string& prefix) {
    return prefix + ": I/O operation failed";
}

} // namespace

FileReadResult Win32FileSystem::readUtf8(const std::string& path) {
#ifdef _WIN32
    const auto handle = CreateFileW(wide(path).c_str(), GENERIC_READ,
                                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return {false, {}, winError()};
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(handle, &size) || size.QuadPart < 0 || size.QuadPart > 64 * 1024 * 1024) {
        CloseHandle(handle);
        return {false, {}, "File is too large"};
    }
    std::string text(static_cast<std::size_t>(size.QuadPart), '\0');
    DWORD read = 0;
    const bool ok = text.empty() || ReadFile(handle, text.data(), static_cast<DWORD>(text.size()), &read, nullptr);
    CloseHandle(handle);
    if (!ok) return {false, {}, winError()};
    text.resize(read);
    return {true, std::move(text), {}};
#else
    std::ifstream input(path, std::ios::binary);
    if (!input) return {false, {}, ioError("read")};
    std::ostringstream buffer;
    buffer << input.rdbuf();
    return {true, buffer.str(), {}};
#endif
}

bool Win32FileSystem::writeAtomic(const std::string& path,
                                  const std::string& text,
                                  std::string& error) {
    const std::filesystem::path target(path);
    std::error_code filesystemError;
    if (!target.parent_path().empty()) {
        std::filesystem::create_directories(target.parent_path(), filesystemError);
        if (filesystemError) {
            error = filesystemError.message();
            return false;
        }
    }
    const auto temporary = target.string() + ".lithe-tmp-" + std::to_string(std::random_device{}());
#ifdef _WIN32
    const auto temporaryWide = wide(temporary);
    const auto targetWide = wide(path);
    const auto handle = CreateFileW(temporaryWide.c_str(), GENERIC_WRITE, 0, nullptr,
                                    CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (handle == INVALID_HANDLE_VALUE) { error = winError(); return false; }
    DWORD written = 0;
    const bool wrote = text.empty() || WriteFile(handle, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
    const bool flushed = wrote && FlushFileBuffers(handle);
    CloseHandle(handle);
    if (!wrote || !flushed || written != text.size()) {
        DeleteFileW(temporaryWide.c_str());
        error = winError();
        return false;
    }
    if (!MoveFileExW(temporaryWide.c_str(), targetWide.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temporaryWide.c_str());
        error = winError();
        return false;
    }
#else
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output || !(output << text)) {
            error = ioError("write");
            std::filesystem::remove(temporary, filesystemError);
            return false;
        }
        output.flush();
    }
    std::filesystem::rename(temporary, target, filesystemError);
    if (filesystemError) {
        std::filesystem::remove(temporary, filesystemError);
        error = filesystemError.message();
        return false;
    }
#endif
    return true;
}

bool Win32FileSystem::move(const std::string& source,
                           const std::string& destination,
                           std::string& error) {
#ifdef _WIN32
    if (!MoveFileExW(wide(source).c_str(), wide(destination).c_str(), MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH)) {
        error = winError();
        return false;
    }
    return true;
#else
    std::error_code filesystemError;
    std::filesystem::rename(source, destination, filesystemError);
    if (filesystemError) { error = filesystemError.message(); return false; }
    return true;
#endif
}

bool Win32FileSystem::remove(const std::string& path, std::string& error) {
#ifdef _WIN32
    if (!DeleteFileW(wide(path).c_str())) { error = winError(); return false; }
    return true;
#else
    std::error_code filesystemError;
    if (!std::filesystem::remove(path, filesystemError) || filesystemError) {
        error = filesystemError ? filesystemError.message() : "Path does not exist";
        return false;
    }
    return true;
#endif
}

} // namespace lithe::windows
