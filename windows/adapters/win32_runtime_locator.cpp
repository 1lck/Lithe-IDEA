#include "win32_runtime_locator.h"

#include <cstdlib>
#include <filesystem>
#include <string>

#ifdef _WIN32
#include <windows.h>
#endif

namespace lithe::windows {
namespace {

std::string environment(const char* name) {
    const auto* value = std::getenv(name);
    return value == nullptr ? std::string{} : std::string(value);
}

std::string findExecutable(const std::string& name) {
#ifdef _WIN32
    std::wstring wideName(name.begin(), name.end());
    wchar_t buffer[32768];
    const DWORD length = SearchPathW(nullptr, wideName.c_str(), L".exe", sizeof(buffer) / sizeof(wchar_t), buffer, nullptr);
    if (length == 0 || length >= sizeof(buffer) / sizeof(wchar_t)) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<std::size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(length), result.data(), bytes, nullptr, nullptr);
    return result;
#else
    const auto path = std::filesystem::path("/usr/bin") / name;
    return std::filesystem::exists(path) ? path.string() : std::string{};
#endif
}

} // namespace

RuntimeDiscoveryResult Win32RuntimeLocator::discover() const {
    RuntimeDiscoveryResult result;
    const auto javaHome = environment("JAVA_HOME");
    const auto java = javaHome.empty()
        ? findExecutable("java")
        : (std::filesystem::path(javaHome) / "bin" / "java.exe").string();
    if (!java.empty() && (javaHome.empty() || std::filesystem::exists(java))) {
        result.javaRuntimes.push_back(RuntimeCandidate{javaHome, java, {}});
    }

    const auto mavenHome = environment("MAVEN_HOME");
    const auto maven = mavenHome.empty()
        ? findExecutable("mvn")
        : (std::filesystem::path(mavenHome) / "bin" / "mvn.cmd").string();
    if (!maven.empty() && (mavenHome.empty() || std::filesystem::exists(maven))) {
        result.mavenRuntimes.push_back(RuntimeCandidate{mavenHome, maven, {}});
    }
    return result;
}

} // namespace lithe::windows
