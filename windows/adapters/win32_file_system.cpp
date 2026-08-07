#include "win32_file_system.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <random>
#include <sstream>
#include <string_view>
#include <system_error>

#ifdef _WIN32
#include <windows.h>
#endif

namespace lithe::windows {
namespace {

constexpr std::uint64_t MaxCoreFileSize = 2ull * 1024ull * 1024ull;

std::string ioError(const std::string& prefix) {
    return prefix + ": I/O operation failed";
}

std::string encodeCodePoint(std::uint32_t value) {
    if (value <= 0x7f) return std::string(1, static_cast<char>(value));
    if (value <= 0x7ff) {
        return {static_cast<char>(0xc0 | (value >> 6)),
                static_cast<char>(0x80 | (value & 0x3f))};
    }
    if (value <= 0xffff) {
        return {static_cast<char>(0xe0 | (value >> 12)),
                static_cast<char>(0x80 | ((value >> 6) & 0x3f)),
                static_cast<char>(0x80 | (value & 0x3f))};
    }
    return {static_cast<char>(0xf0 | (value >> 18)),
            static_cast<char>(0x80 | ((value >> 12) & 0x3f)),
            static_cast<char>(0x80 | ((value >> 6) & 0x3f)),
            static_cast<char>(0x80 | (value & 0x3f))};
}

std::string decodeUtf16(std::string_view bytes, bool littleEndian) {
    std::string result;
    result.reserve(bytes.size());
    auto unitAt = [&](std::size_t index) -> std::uint16_t {
        const auto first = static_cast<unsigned char>(bytes[index]);
        const auto second = static_cast<unsigned char>(bytes[index + 1]);
        return littleEndian
            ? static_cast<std::uint16_t>(first | (second << 8))
            : static_cast<std::uint16_t>((first << 8) | second);
    };
    for (std::size_t index = 0; index + 1 < bytes.size(); index += 2) {
        const auto first = unitAt(index);
        std::uint32_t codePoint = first;
        if (first >= 0xd800 && first <= 0xdbff) {
            if (index + 3 >= bytes.size()) {
                result += "\xef\xbf\xbd";
                continue;
            }
            const auto second = unitAt(index + 2);
            if (second >= 0xdc00 && second <= 0xdfff) {
                codePoint = 0x10000u + ((first - 0xd800u) << 10u) +
                    (second - 0xdc00u);
                index += 2;
            } else {
                result += "\xef\xbf\xbd";
                continue;
            }
        } else if (first >= 0xdc00 && first <= 0xdfff) {
            result += "\xef\xbf\xbd";
            continue;
        }
        result += encodeCodePoint(codePoint);
    }
    return result;
}

bool isValidUtf8(std::string_view value) {
    std::size_t index = 0;
    while (index < value.size()) {
        const auto first = static_cast<unsigned char>(value[index]);
        std::size_t expected = 0;
        if (first <= 0x7f) expected = 1;
        else if (first >= 0xc2 && first <= 0xdf) expected = 2;
        else if (first >= 0xe0 && first <= 0xef) expected = 3;
        else if (first >= 0xf0 && first <= 0xf4) expected = 4;
        else return false;
        if (index + expected > value.size()) return false;
        for (std::size_t offset = 1; offset < expected; ++offset) {
            if ((static_cast<unsigned char>(value[index + offset]) & 0xc0) != 0x80) {
                return false;
            }
        }
        if (expected == 3) {
            const auto second = static_cast<unsigned char>(value[index + 1]);
            if ((first == 0xe0 && second < 0xa0) ||
                (first == 0xed && second >= 0xa0)) return false;
        }
        if (expected == 4) {
            const auto second = static_cast<unsigned char>(value[index + 1]);
            if ((first == 0xf0 && second < 0x90) ||
                (first == 0xf4 && second >= 0x90)) return false;
        }
        index += expected;
    }
    return true;
}

std::string decodeText(std::string bytes) {
    if (bytes.size() >= 3 && static_cast<unsigned char>(bytes[0]) == 0xef &&
        static_cast<unsigned char>(bytes[1]) == 0xbb &&
        static_cast<unsigned char>(bytes[2]) == 0xbf) {
        bytes.erase(0, 3);
        return bytes;
    }
    if (bytes.size() >= 2 && static_cast<unsigned char>(bytes[0]) == 0xff &&
        static_cast<unsigned char>(bytes[1]) == 0xfe) {
        return decodeUtf16(std::string_view(bytes).substr(2), true);
    }
    if (bytes.size() >= 2 && static_cast<unsigned char>(bytes[0]) == 0xfe &&
        static_cast<unsigned char>(bytes[1]) == 0xff) {
        return decodeUtf16(std::string_view(bytes).substr(2), false);
    }
    return bytes;
}

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

std::wstring longPath(std::wstring path) {
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.size() < MAX_PATH || path.rfind(L"\\\\?\\", 0) == 0) return path;
    if (path.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC" + path.substr(1);
    return L"\\\\?\\" + path;
}

#endif

std::filesystem::path pathFromUtf8(const std::string& value) {
    const auto* data = reinterpret_cast<const char8_t*>(value.data());
    return std::filesystem::path(std::u8string(data, data + value.size()));
}

std::string temporaryPath(const std::filesystem::path& target) {
    static std::atomic<std::uint64_t> counter{0};
    const auto encoded = target.u8string();
    const std::string targetUtf8(reinterpret_cast<const char*>(encoded.data()), encoded.size());
    return targetUtf8 + ".lithe-tmp-" +
        std::to_string(counter.fetch_add(1, std::memory_order_relaxed));
}

} // namespace

FileReadResult Win32FileSystem::readUtf8(const std::string& path) {
#ifdef _WIN32
    const auto converted = wide(path);
    if (!converted) return {false, {}, "Path is not valid UTF-8"};
    const auto handle = CreateFileW(
        longPath(*converted).c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return {false, {}, winError()};
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(handle, &size) || size.QuadPart < 0 ||
        static_cast<std::uint64_t>(size.QuadPart) > MaxCoreFileSize) {
        CloseHandle(handle);
        return {false, {}, "File is too large"};
    }
    std::string bytes(static_cast<std::size_t>(size.QuadPart), '\0');
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        DWORD read = 0;
        const auto remaining = std::min<std::size_t>(bytes.size() - offset,
                                                      std::numeric_limits<DWORD>::max());
        if (!ReadFile(handle, bytes.data() + offset, static_cast<DWORD>(remaining),
                      &read, nullptr)) {
            const auto error = winError();
            CloseHandle(handle);
            return {false, {}, error};
        }
        if (read == 0) break;
        offset += read;
    }
    CloseHandle(handle);
    bytes.resize(offset);
    auto text = decodeText(std::move(bytes));
    if (!isValidUtf8(text)) return {false, {}, "File is not valid UTF-8"};
    return {true, std::move(text), {}};
#else
    std::ifstream input(path, std::ios::binary);
    if (!input) return {false, {}, ioError("read")};
    input.seekg(0, std::ios::end);
    const auto size = input.tellg();
    if (size < 0 || static_cast<std::uint64_t>(size) > MaxCoreFileSize) {
        return {false, {}, "File is too large"};
    }
    input.seekg(0, std::ios::beg);
    std::string bytes(static_cast<std::size_t>(size), '\0');
    if (!bytes.empty()) input.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    if (!input && !input.eof()) return {false, {}, ioError("read")};
    bytes.resize(static_cast<std::size_t>(input.gcount()));
    auto text = decodeText(std::move(bytes));
    if (!isValidUtf8(text)) return {false, {}, "File is not valid UTF-8"};
    return {true, std::move(text), {}};
#endif
}

bool Win32FileSystem::writeAtomic(const std::string& path,
                                  const std::string& text,
                                  std::string& error) {
    const auto target = pathFromUtf8(path);
    std::error_code filesystemError;
    if (!target.parent_path().empty()) {
        std::filesystem::create_directories(target.parent_path(), filesystemError);
        if (filesystemError) {
            error = filesystemError.message();
            return false;
        }
    }
    const auto temporary = temporaryPath(target);
#ifdef _WIN32
    const auto temporaryWide = wide(temporary);
    const auto targetWide = wide(path);
    if (!temporaryWide || !targetWide) {
        error = "Path is not valid UTF-8";
        return false;
    }
    const auto handle = CreateFileW(
        longPath(*temporaryWide).c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        error = winError();
        return false;
    }
    std::size_t offset = 0;
    bool wrote = true;
    while (offset < text.size()) {
        DWORD written = 0;
        const auto remaining = std::min<std::size_t>(
            text.size() - offset, std::numeric_limits<DWORD>::max());
        if (!WriteFile(handle, text.data() + offset, static_cast<DWORD>(remaining),
                       &written, nullptr) || written == 0) {
            wrote = false;
            break;
        }
        offset += written;
    }
    const auto writeError = wrote ? ERROR_SUCCESS : GetLastError();
    const bool flushed = wrote && FlushFileBuffers(handle);
    const auto flushError = flushed ? ERROR_SUCCESS : GetLastError();
    CloseHandle(handle);
    if (!wrote || !flushed || offset != text.size()) {
        DeleteFileW(longPath(*temporaryWide).c_str());
        error = winError(wrote ? flushError : writeError);
        return false;
    }
    if (!MoveFileExW(longPath(*temporaryWide).c_str(), longPath(*targetWide).c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        const auto moveError = GetLastError();
        DeleteFileW(longPath(*temporaryWide).c_str());
        error = winError(moveError);
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
        if (!output) {
            error = ioError("flush");
            std::filesystem::remove(temporary, filesystemError);
            return false;
        }
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
    const auto sourceWide = wide(source);
    const auto destinationWide = wide(destination);
    if (!sourceWide || !destinationWide) {
        error = "Path is not valid UTF-8";
        return false;
    }
    if (!MoveFileExW(longPath(*sourceWide).c_str(), longPath(*destinationWide).c_str(),
                     MOVEFILE_COPY_ALLOWED | MOVEFILE_REPLACE_EXISTING |
                         MOVEFILE_WRITE_THROUGH)) {
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
    const auto converted = wide(path);
    if (!converted) {
        error = "Path is not valid UTF-8";
        return false;
    }
    const auto nativePath = longPath(*converted);
    const auto attributes = GetFileAttributesW(nativePath.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        error = winError();
        return false;
    }
    if (attributes & FILE_ATTRIBUTE_READONLY) {
        SetFileAttributesW(nativePath.c_str(), attributes & ~FILE_ATTRIBUTE_READONLY);
    }
    const bool removed = (attributes & FILE_ATTRIBUTE_DIRECTORY)
        ? RemoveDirectoryW(nativePath.c_str()) != FALSE
        : DeleteFileW(nativePath.c_str()) != FALSE;
    if (!removed) error = winError();
    return removed;
#else
    std::error_code filesystemError;
    const auto count = std::filesystem::remove_all(path, filesystemError);
    if (filesystemError) { error = filesystemError.message(); return false; }
    if (count == 0) { error = "Path does not exist"; return false; }
    return true;
#endif
}

} // namespace lithe::windows
