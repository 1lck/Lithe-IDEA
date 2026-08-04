#include "win32_key_value_store.h"

#include <cstdlib>
#include <fstream>
#include <sstream>

namespace lithe::windows {
namespace {

std::filesystem::path defaultRoot() {
    const auto* appData = std::getenv("APPDATA");
    if (appData != nullptr && *appData != '\0') return std::filesystem::path(appData) / "Lithe" / "state";
    const auto* localData = std::getenv("LOCALAPPDATA");
    if (localData != nullptr && *localData != '\0') return std::filesystem::path(localData) / "Lithe" / "state";
    return std::filesystem::temp_directory_path() / "Lithe" / "state";
}

std::string safeKey(std::string key) {
    for (char& character : key) {
        if (character == '/' || character == '\\' || character == ':' || character == '\0') character = '_';
    }
    return key.empty() ? "default" : key;
}

} // namespace

Win32KeyValueStore::Win32KeyValueStore(std::filesystem::path root)
    : root_(root.empty() ? defaultRoot() : std::move(root)) {}

std::filesystem::path Win32KeyValueStore::pathForKey(const std::string& key) const {
    return root_ / (safeKey(key) + ".value");
}

std::optional<std::string> Win32KeyValueStore::read(const std::string& key) const {
    std::ifstream input(pathForKey(key), std::ios::binary);
    if (!input) return std::nullopt;
    std::ostringstream value;
    value << input.rdbuf();
    return value.str();
}

bool Win32KeyValueStore::write(const std::string& key,
                               const std::string& value,
                               std::string& error) {
    std::error_code filesystemError;
    std::filesystem::create_directories(root_, filesystemError);
    if (filesystemError) { error = filesystemError.message(); return false; }
    const auto path = pathForKey(key);
    const auto temporary = path.string() + ".tmp";
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output || !(output << value)) { error = "Could not write persisted value"; return false; }
        output.flush();
    }
#ifdef _WIN32
    std::filesystem::remove(path, filesystemError);
    filesystemError.clear();
#endif
    std::filesystem::rename(temporary, path, filesystemError);
    if (filesystemError) {
        std::filesystem::remove(temporary, filesystemError);
        error = filesystemError.message();
        return false;
    }
    return true;
}

bool Win32KeyValueStore::remove(const std::string& key, std::string& error) {
    std::error_code filesystemError;
    if (!std::filesystem::remove(pathForKey(key), filesystemError) || filesystemError) {
        error = filesystemError ? filesystemError.message() : "Persisted value does not exist";
        return false;
    }
    return true;
}

} // namespace lithe::windows
