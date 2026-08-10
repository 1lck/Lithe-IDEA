#include "win32_file_storage.h"

#include "win32_file_system.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <system_error>

#ifdef _WIN32
#include <shlobj.h>
#else
#include <unistd.h>
#endif

namespace lithe::windows {
namespace {

std::filesystem::path pathFromUtf8(const std::string& value) {
    const auto* data = reinterpret_cast<const char8_t*>(value.data());
    return std::filesystem::path(std::u8string(data, data + value.size()));
}

std::string pathToUtf8(const std::filesystem::path& value) {
    const auto text = value.u8string();
    return {reinterpret_cast<const char*>(text.data()), text.size()};
}

std::string errorMessage(const std::string& prefix, const std::error_code& error) {
    return prefix + ": " + (error ? error.message() : "operation failed");
}

#ifdef _WIN32
std::string knownFolder(REFKNOWNFOLDERID id) {
    PWSTR value = nullptr;
    if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &value)) || value == nullptr) {
        if (value != nullptr) CoTaskMemFree(value);
        return {};
    }
    std::wstring path(value);
    CoTaskMemFree(value);
    const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          path.data(), static_cast<int>(path.size()),
                                          nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string result(static_cast<std::size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
                        static_cast<int>(path.size()), result.data(), bytes,
                        nullptr, nullptr);
    return result;
}
#endif

} // namespace

std::string Win32FileStorage::homeDirectory() const {
#ifdef _WIN32
    return knownFolder(FOLDERID_Profile);
#else
    const auto* value = std::getenv("HOME");
    return value == nullptr ? std::string{} : std::string(value);
#endif
}

std::string Win32FileStorage::cacheDirectory() const {
#ifdef _WIN32
    const auto root = knownFolder(FOLDERID_LocalAppData);
    return root.empty() ? std::string{} : pathToUtf8(pathFromUtf8(root) / "Lithe" / "cache");
#else
    const auto* value = std::getenv("XDG_CACHE_HOME");
    if (value != nullptr && *value != '\0') return value;
    const auto home = homeDirectory();
    return home.empty() ? std::string{} : pathToUtf8(pathFromUtf8(home) / ".cache" / "Lithe");
#endif
}

std::string Win32FileStorage::applicationSupportDirectory() const {
#ifdef _WIN32
    const auto root = knownFolder(FOLDERID_RoamingAppData);
    return root.empty() ? std::string{} : pathToUtf8(pathFromUtf8(root) / "Lithe");
#else
    const auto* value = std::getenv("XDG_CONFIG_HOME");
    if (value != nullptr && *value != '\0') return pathToUtf8(pathFromUtf8(value) / "Lithe");
    const auto home = homeDirectory();
    return home.empty() ? std::string{} : pathToUtf8(pathFromUtf8(home) / ".config" / "Lithe");
#endif
}

std::optional<FileMetadata> Win32FileStorage::metadata(const std::string& path) const {
    const auto native = pathFromUtf8(path);
    std::error_code error;
    const auto status = std::filesystem::status(native, error);
    if (error || status.type() == std::filesystem::file_type::not_found) return std::nullopt;
    FileMetadata result;
    result.isRegularFile = std::filesystem::is_regular_file(status);
    result.isDirectory = std::filesystem::is_directory(status);
#ifdef _WIN32
    const auto attributes = GetFileAttributesW(native.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES) {
        result.isWritable = (attributes & FILE_ATTRIBUTE_READONLY) == 0;
    }
#endif
    if (result.isRegularFile) {
        const auto size = std::filesystem::file_size(native, error);
        if (!error) result.byteCount = size;
    }
    const auto modified = std::filesystem::last_write_time(native, error);
    if (!error) {
        result.modificationTime = std::chrono::duration_cast<std::chrono::seconds>(
            modified.time_since_epoch()).count();
    }
    return result;
}

bool Win32FileStorage::fileExists(const std::string& path) const {
    return metadata(path).has_value();
}

bool Win32FileStorage::isExecutable(const std::string& path) const {
    const auto value = metadata(path);
    if (!value || !value->isRegularFile) return false;
#ifdef _WIN32
    const auto extension = pathFromUtf8(path).extension().u8string();
    std::string suffix(reinterpret_cast<const char*>(extension.data()), extension.size());
    std::transform(suffix.begin(), suffix.end(), suffix.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return suffix == ".exe" || suffix == ".com" || suffix == ".bat" || suffix == ".cmd";
#else
    return access(path.c_str(), X_OK) == 0;
#endif
}

std::vector<std::string> Win32FileStorage::listDirectory(const std::string& path) const {
    std::vector<std::string> result;
    std::error_code error;
    for (const auto& entry : std::filesystem::directory_iterator(pathFromUtf8(path), error)) {
        if (error) break;
        result.push_back(pathToUtf8(entry.path()));
    }
    std::sort(result.begin(), result.end());
    return result;
}

std::optional<std::vector<std::uint8_t>> Win32FileStorage::readData(
    const std::string& path, std::string& error) const {
    std::ifstream input(pathFromUtf8(path), std::ios::binary);
    if (!input) {
        error = "Could not open file for reading";
        return std::nullopt;
    }
    input.seekg(0, std::ios::end);
    const auto size = input.tellg();
    if (size < 0 || static_cast<unsigned long long>(size) >
            static_cast<unsigned long long>(std::numeric_limits<std::size_t>::max())) {
        error = "File size is invalid";
        return std::nullopt;
    }
    input.seekg(0, std::ios::beg);
    std::vector<std::uint8_t> result(static_cast<std::size_t>(size));
    if (!result.empty()) {
        input.read(reinterpret_cast<char*>(result.data()),
                   static_cast<std::streamsize>(result.size()));
        if (!input) {
            error = "Could not read file";
            return std::nullopt;
        }
    }
    return result;
}

bool Win32FileStorage::writeData(const std::string& path,
                                 const std::vector<std::uint8_t>& data,
                                 std::string& error) {
    const std::string value(reinterpret_cast<const char*>(data.data()), data.size());
    Win32FileSystem files;
    return files.writeAtomic(path, value, error);
}

bool Win32FileStorage::createDirectory(const std::string& path,
                                       bool withIntermediateDirectories,
                                       std::string& error) {
    std::error_code filesystemError;
    const auto native = pathFromUtf8(path);
    const bool created = withIntermediateDirectories
        ? std::filesystem::create_directories(native, filesystemError)
        : std::filesystem::create_directory(native, filesystemError);
    if (filesystemError) {
        error = errorMessage("Could not create directory", filesystemError);
        return false;
    }
    if (!created && !std::filesystem::is_directory(native, filesystemError)) {
        error = "Path is not a directory";
        return false;
    }
    return true;
}

bool Win32FileStorage::removeItem(const std::string& path, std::string& error) {
    Win32FileSystem files;
    return files.remove(path, error);
}

bool Win32FileStorage::moveItem(const std::string& source,
                                const std::string& destination,
                                std::string& error) {
    Win32FileSystem files;
    return files.move(source, destination, error);
}

} // namespace lithe::windows
