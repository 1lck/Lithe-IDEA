#include "win32_runtime_locator.h"

#include "win32_process_runner.h"

#include <algorithm>
#include <cstdlib>
#include <cwchar>
#include <filesystem>
#include <iterator>
#include <map>
#include <optional>
#include <regex>
#include <set>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <winreg.h>
#endif

namespace lithe::windows {
namespace {

std::filesystem::path pathFromUtf8(const std::string& value) {
    const auto* data = reinterpret_cast<const char8_t*>(value.data());
    return std::filesystem::path(std::u8string(data, data + value.size()));
}

std::string pathToUtf8(const std::filesystem::path& value) {
    const auto text = value.generic_u8string();
    return {reinterpret_cast<const char*>(text.data()), text.size()};
}

std::filesystem::path normalize(const std::filesystem::path& value) {
    return value.lexically_normal();
}

bool isRegularFile(const std::filesystem::path& path) {
    std::error_code error;
    return std::filesystem::is_regular_file(path, error) && !error;
}

std::string executableVersion(const std::string& executable,
                              const std::vector<std::string>& arguments) {
    Win32ProcessRunner runner;
    ProcessRequest request;
    request.executablePath = executable;
    request.arguments = arguments;
    request.timeoutMilliseconds = 5000;
    const auto result = runner.run(request);
    const std::string output = result.output;
    const auto quote = output.find("version \"");
    if (quote != std::string::npos) {
        const auto start = quote + 9;
        const auto end = output.find('"', start);
        if (end != std::string::npos) return output.substr(start, end - start);
    }
    static const std::regex mavenPattern(R"(Apache Maven\s+([^\s\r\n]+))");
    std::smatch match;
    if (std::regex_search(output, match, mavenPattern) && match.size() > 1) {
        return match[1].str();
    }
    return {};
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

std::string narrow(const wchar_t* value, int length = -1) {
    if (value == nullptr) return {};
    if (length < 0) length = static_cast<int>(wcslen(value));
    const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          value, length, nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string result(static_cast<std::size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length,
                        result.data(), bytes, nullptr, nullptr);
    return result;
}

std::string environmentValue(const char* name) {
    std::wstring wideName(name, name + std::char_traits<char>::length(name));
    const auto length = GetEnvironmentVariableW(wideName.c_str(), nullptr, 0);
    if (length == 0) return {};
    // The zero-sized query has differed between older Windows SDK contracts
    // about whether the terminator is included.  Leave one extra code unit so
    // either interpretation is safe.
    std::wstring value(static_cast<std::size_t>(length) + 1, L'\0');
    const auto copied = GetEnvironmentVariableW(
        wideName.c_str(), value.data(), static_cast<DWORD>(value.size()));
    if (copied == 0 || copied >= value.size()) return {};
    value.resize(copied);
    return narrow(value.data(), static_cast<int>(value.size()));
}

std::optional<std::string> registryString(HKEY root, const std::wstring& key,
                                          const std::wstring& valueName,
                                          REGSAM view = 0) {
    HKEY handle = nullptr;
    if (view != 0) {
        if (RegOpenKeyExW(root, key.c_str(), 0, KEY_READ | view, &handle) != ERROR_SUCCESS) {
            return std::nullopt;
        }
    } else if (RegOpenKeyExW(root, key.c_str(), 0, KEY_READ | KEY_WOW64_64KEY, &handle) !=
                   ERROR_SUCCESS &&
               RegOpenKeyExW(root, key.c_str(), 0, KEY_READ | KEY_WOW64_32KEY, &handle) !=
                   ERROR_SUCCESS) {
        return std::nullopt;
    }
    DWORD type = 0;
    DWORD bytes = 0;
    auto status = RegQueryValueExW(handle, valueName.c_str(), nullptr, &type, nullptr, &bytes);
    if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) || bytes == 0) {
        RegCloseKey(handle);
        return std::nullopt;
    }
    std::wstring value(bytes / sizeof(wchar_t), L'\0');
    status = RegQueryValueExW(handle, valueName.c_str(), nullptr, &type,
                              reinterpret_cast<LPBYTE>(value.data()), &bytes);
    RegCloseKey(handle);
    if (status != ERROR_SUCCESS) return std::nullopt;
    if (!value.empty() && value.back() == L'\0') value.pop_back();
    return narrow(value.c_str(), static_cast<int>(value.size()));
}

void registryHomes(HKEY root, const std::wstring& base, std::vector<std::string>& result,
                   REGSAM view) {
    DWORD count = 0;
    HKEY handle = nullptr;
    if (RegOpenKeyExW(root, base.c_str(), 0, KEY_READ | view, &handle) != ERROR_SUCCESS) {
        return;
    }
    if (auto current = registryString(root, base, L"CurrentVersion", view)) {
        if (auto currentWide = wide(*current)) {
            if (auto home = registryString(root, base + L"\\" + *currentWide, L"JavaHome",
                                           view)) {
                result.push_back(*home);
            }
        }
    }
    if (RegQueryInfoKeyW(handle, nullptr, nullptr, nullptr, &count, nullptr, nullptr,
                         nullptr, nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS) {
        for (DWORD index = 0; index < count; ++index) {
            wchar_t name[256];
            DWORD length = static_cast<DWORD>(std::size(name));
            if (RegEnumKeyExW(handle, index, name, &length, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) {
                continue;
            }
            if (auto home = registryString(root,
                                           base + L"\\" + std::wstring(name, length),
                                           L"JavaHome", view)) {
                result.push_back(*home);
            }
        }
    }
    RegCloseKey(handle);
}

std::string searchPath(const std::vector<std::wstring>& names) {
    wchar_t buffer[32768];
    for (const auto& name : names) {
        const auto length = SearchPathW(nullptr, name.c_str(), nullptr,
                                        static_cast<DWORD>(std::size(buffer)), buffer, nullptr);
        if (length == 0 || length >= std::size(buffer)) continue;
        return narrow(buffer, static_cast<int>(length));
    }
    return {};
}

#else

std::string environmentValue(const char* name) {
    const auto* value = std::getenv(name);
    return value == nullptr ? std::string{} : std::string(value);
}

std::string searchPath(const std::vector<std::wstring>& names) {
    for (const auto& name : names) {
        std::string value(name.begin(), name.end());
        const auto path = std::filesystem::path("/usr/bin") / value;
        if (isRegularFile(path)) return pathToUtf8(path);
    }
    return {};
}

#endif

void addDirectoryChildren(const std::filesystem::path& root,
                          std::vector<std::string>& candidates) {
    std::error_code error;
    if (!std::filesystem::is_directory(root, error) || error) return;
    for (const auto& entry : std::filesystem::directory_iterator(root, error)) {
        if (error) break;
        std::error_code childError;
        if (std::filesystem::is_directory(entry.path(), childError) && !childError) {
            candidates.push_back(pathToUtf8(entry.path()));
        }
    }
}

std::string javaExecutableForHome(const std::string& home) {
    const auto root = pathFromUtf8(home);
#ifdef _WIN32
    for (const auto& relative : {"bin/java.exe", "bin/java"}) {
        const auto candidate = root / relative;
        if (isRegularFile(candidate)) return pathToUtf8(candidate);
    }
#else
    const auto candidate = root / "bin/java";
    if (isRegularFile(candidate)) return pathToUtf8(candidate);
#endif
    return {};
}

std::string mavenExecutableForHome(const std::string& home) {
    const auto root = pathFromUtf8(home);
#ifdef _WIN32
    for (const auto& relative : {"bin/mvn.cmd", "bin/mvn.bat", "bin/mvn.exe", "bin/mvn"}) {
        const auto candidate = root / relative;
        if (isRegularFile(candidate)) return pathToUtf8(candidate);
    }
#else
    const auto candidate = root / "bin/mvn";
    if (isRegularFile(candidate)) return pathToUtf8(candidate);
#endif
    return {};
}

} // namespace

std::map<std::string, std::string> Win32RuntimeLocator::environment() const {
    std::map<std::string, std::string> result;
#ifdef _WIN32
    LPWCH raw = GetEnvironmentStringsW();
    if (raw == nullptr) return result;
    for (const wchar_t* cursor = raw; *cursor != L'\0';) {
        std::wstring entry(cursor);
        cursor += entry.size() + 1;
        const auto separator = entry.find(L'=');
        if (separator == std::wstring::npos || separator == 0) continue;
        result[narrow(entry.data(), static_cast<int>(separator))] =
            narrow(entry.data() + separator + 1,
                   static_cast<int>(entry.size() - separator - 1));
    }
    FreeEnvironmentStringsW(raw);
#else
    for (const auto* name : {"JAVA_HOME", "MAVEN_HOME", "PATH", "USERPROFILE", "HOME"}) {
        const auto value = environmentValue(name);
        if (!value.empty()) result[name] = value;
    }
#endif
    return result;
}

bool Win32RuntimeLocator::isExecutable(const std::string& path) const {
    return isRegularFile(pathFromUtf8(path));
}

std::optional<std::string> Win32RuntimeLocator::validJavaHome(const std::string& path) const {
    if (path.empty()) return std::nullopt;
    const auto home = normalize(pathFromUtf8(path));
    const auto executable = javaExecutableForHome(pathToUtf8(home));
    return executable.empty() ? std::nullopt : std::optional<std::string>(pathToUtf8(home));
}

RuntimeDiscoveryResult Win32RuntimeLocator::discover() const {
    RuntimeDiscoveryResult result;
    std::vector<std::string> javaHomes;
    const auto javaHome = environmentValue("JAVA_HOME");
    if (!javaHome.empty()) javaHomes.push_back(javaHome);
#ifdef _WIN32
    const REGSAM registryViews[] = {KEY_WOW64_64KEY, KEY_WOW64_32KEY};
    for (const auto view : registryViews) {
        registryHomes(HKEY_LOCAL_MACHINE, L"SOFTWARE\\JavaSoft\\JDK", javaHomes, view);
        registryHomes(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Eclipse Adoptium\\JDK", javaHomes,
                      view);
        registryHomes(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\JDK", javaHomes, view);
        registryHomes(HKEY_CURRENT_USER, L"SOFTWARE\\JavaSoft\\JDK", javaHomes, view);
    }
    const auto programFiles = environmentValue("ProgramFiles");
    const auto localAppData = environmentValue("LOCALAPPDATA");
    const auto userProfile = environmentValue("USERPROFILE");
    for (const auto& root : {
             programFiles + "\\Java", programFiles + "\\Eclipse Adoptium",
             programFiles + "\\Microsoft", localAppData + "\\Programs\\Eclipse Adoptium",
             userProfile + "\\.jdks"}) {
        if (!root.empty()) addDirectoryChildren(pathFromUtf8(root), javaHomes);
    }
#else
    addDirectoryChildren("/Library/Java/JavaVirtualMachines", javaHomes);
    addDirectoryChildren(pathFromUtf8(environmentValue("HOME")) /
                             "Library/Java/JavaVirtualMachines", javaHomes);
#endif
    std::set<std::string> uniqueHomes;
    for (const auto& candidate : javaHomes) {
        const auto home = validJavaHome(candidate);
        if (!home || !uniqueHomes.insert(*home).second) continue;
        const auto executable = javaExecutableForHome(*home);
        const auto version = executableVersion(executable, {"-version"});
        if (!version.empty()) result.javaRuntimes.push_back({*home, executable, version});
    }

    std::vector<std::string> mavenExecutables;
    const auto mavenHome = environmentValue("MAVEN_HOME");
    if (!mavenHome.empty()) {
        const auto executable = mavenExecutableForHome(mavenHome);
        if (!executable.empty()) mavenExecutables.push_back(executable);
    }
#ifdef _WIN32
    const auto pathExecutable = searchPath({L"mvn.cmd", L"mvn.bat", L"mvn.exe", L"mvn"});
#else
    const auto pathExecutable = searchPath({L"mvn"});
#endif
    if (!pathExecutable.empty()) mavenExecutables.push_back(pathExecutable);
    std::set<std::string> uniqueMaven;
    for (const auto& executable : mavenExecutables) {
        if (!uniqueMaven.insert(executable).second) continue;
        const auto version = executableVersion(executable, {"-version"});
        const auto home = pathFromUtf8(executable).parent_path().parent_path();
        result.mavenRuntimes.push_back({pathToUtf8(home), executable, version});
    }
    std::sort(result.javaRuntimes.begin(), result.javaRuntimes.end(),
              [](const auto& left, const auto& right) { return left.version > right.version; });
    std::sort(result.mavenRuntimes.begin(), result.mavenRuntimes.end(),
              [](const auto& left, const auto& right) { return left.version > right.version; });
    return result;
}

std::optional<std::string> Win32RuntimeLocator::systemMavenExecutable() const {
    const auto home = environmentValue("MAVEN_HOME");
    if (!home.empty()) {
        const auto executable = mavenExecutableForHome(home);
        if (!executable.empty()) return executable;
    }
#ifdef _WIN32
    const auto executable = searchPath({L"mvn.cmd", L"mvn.bat", L"mvn.exe", L"mvn"});
#else
    const auto executable = searchPath({L"mvn"});
#endif
    return executable.empty() ? std::nullopt : std::optional<std::string>(executable);
}

std::optional<std::string> Win32RuntimeLocator::mavenExecutableForHomePath(
    const std::string& path) const {
    const auto executable = mavenExecutableForHome(path);
    return executable.empty() ? std::nullopt : std::optional<std::string>(executable);
}

std::optional<std::string> Win32RuntimeLocator::systemJDBExecutable() const {
    const auto javaHome = environmentValue("JAVA_HOME");
    if (!javaHome.empty()) {
        const auto candidate = pathFromUtf8(javaHome) /
#ifdef _WIN32
            "bin/jdb.exe";
#else
            "bin/jdb";
#endif
        if (isRegularFile(candidate)) return pathToUtf8(candidate);
    }
#ifdef _WIN32
    const auto executable = searchPath({L"jdb.exe", L"jdb"});
#else
    const auto executable = searchPath({L"jdb"});
#endif
    return executable.empty() ? std::nullopt : std::optional<std::string>(executable);
}

std::optional<std::string> Win32RuntimeLocator::javaLanguageServerExecutable() const {
    const auto configured = environmentValue("JDTLS_HOME");
    if (!configured.empty()) {
        const auto root = pathFromUtf8(configured);
        for (const auto& relative : {
#ifdef _WIN32
                 "bin/jdtls.cmd", "bin/jdtls.exe", "jdtls.cmd", "jdtls.exe",
#else
                 "bin/jdtls", "jdtls",
#endif
             }) {
            const auto candidate = root / relative;
            if (isRegularFile(candidate)) return pathToUtf8(candidate);
        }
    }
#ifdef _WIN32
    const auto executable = searchPath({L"jdtls.cmd", L"jdtls.exe", L"jdtls"});
#else
    const auto executable = searchPath({L"jdtls"});
#endif
    return executable.empty() ? std::nullopt : std::optional<std::string>(executable);
}

} // namespace lithe::windows
