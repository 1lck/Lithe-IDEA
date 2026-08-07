#include "project_runtime_service.h"

#include <algorithm>
#include <cctype>
#include <string_view>
#include <utility>

namespace lithe::windows::app {
namespace {

std::string trim(std::string value) {
    const auto isSpace = [](unsigned char character) {
        return std::isspace(character) != 0;
    };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(),
        [&](char character) { return !isSpace(static_cast<unsigned char>(character)); }));
    value.erase(std::find_if(value.rbegin(), value.rend(),
        [&](char character) { return !isSpace(static_cast<unsigned char>(character)); }).base(),
        value.end());
    return value;
}

std::string javaBinName(const char* name) {
#ifdef _WIN32
    return std::string(name) + ".exe";
#else
    return name;
#endif
}

bool environmentKeyEquals(std::string_view left, std::string_view right) {
#ifdef _WIN32
    if (left.size() != right.size()) return false;
    for (std::size_t index = 0; index < left.size(); ++index) {
        if (std::tolower(static_cast<unsigned char>(left[index])) !=
            std::tolower(static_cast<unsigned char>(right[index]))) {
            return false;
        }
    }
    return true;
#else
    return left == right;
#endif
}

std::map<std::string, std::string>::const_iterator findEnvironment(
    const std::map<std::string, std::string>& values,
    std::string_view key) {
    return std::find_if(values.begin(), values.end(), [&](const auto& entry) {
        return environmentKeyEquals(entry.first, key);
    });
}

} // namespace

ProjectRuntimeService::ProjectRuntimeService(RuntimeLocator& locator)
    : locator_(locator) {}

RuntimeDiscoveryResult ProjectRuntimeService::discover() const {
    return locator_.discover();
}

std::optional<std::string> ProjectRuntimeService::javaHome(
    const ProjectRuntimeSettings& settings,
    std::string overridePath) const {
    std::vector<std::string> candidates;
    if (!trim(overridePath).empty()) candidates.push_back(std::move(overridePath));
    if (!settings.javaHomePath.empty()) candidates.push_back(settings.javaHomePath);
    const auto environment = locator_.environment();
    if (const auto found = findEnvironment(environment, "JAVA_HOME");
        found != environment.end()) {
        candidates.push_back(found->second);
    }
    if (const auto home = firstValidJavaHome(candidates)) return home;
    for (const auto& candidate : locator_.discover().javaRuntimes) {
        if (const auto home = locator_.validJavaHome(candidate.homePath)) return home;
    }
    return std::nullopt;
}

std::optional<std::string> ProjectRuntimeService::mavenJavaHome(
    const ProjectRuntimeSettings& settings,
    std::string overridePath) const {
    std::vector<std::string> candidates;
    if (!trim(overridePath).empty()) candidates.push_back(std::move(overridePath));
    if (!settings.mavenJavaHomePath.empty()) candidates.push_back(settings.mavenJavaHomePath);
    if (!settings.javaHomePath.empty()) candidates.push_back(settings.javaHomePath);
    const auto environment = locator_.environment();
    if (const auto found = findEnvironment(environment, "JAVA_HOME");
        found != environment.end()) {
        candidates.push_back(found->second);
    }
    if (const auto home = firstValidJavaHome(candidates)) return home;
    return javaHome(settings);
}

std::optional<std::string> ProjectRuntimeService::javaExecutable(
    const ProjectRuntimeSettings& settings,
    std::string overridePath) const {
    const auto home = javaHome(settings, std::move(overridePath));
    if (!home) return std::nullopt;
    const auto executable = pathFromUtf8(*home) / "bin" / javaBinName("java");
    if (!locator_.isExecutable(pathUtf8(executable))) return std::nullopt;
    return pathUtf8(executable);
}

std::optional<std::string> ProjectRuntimeService::jdbExecutable(
    const ProjectRuntimeSettings& settings,
    RuntimeProcessKind processKind,
    std::string overridePath) const {
    const auto home = processKind == RuntimeProcessKind::Maven
        ? mavenJavaHome(settings, std::move(overridePath))
        : javaHome(settings, std::move(overridePath));
    if (home) {
        const auto executable = pathFromUtf8(*home) / "bin" / javaBinName("jdb");
        if (locator_.isExecutable(pathUtf8(executable))) return pathUtf8(executable);
    }
    return locator_.systemJDBExecutable();
}

std::optional<std::string> ProjectRuntimeService::mavenExecutable(
    const std::filesystem::path& projectRoot,
    const ProjectRuntimeSettings& settings) const {
    const auto root = projectRoot.lexically_normal();
    const auto wrapperCandidates = {
#ifdef _WIN32
        root / "mvnw.cmd", root / "mvnw.bat", root / "mvnw"
#else
        root / "mvnw"
#endif
    };
    if (settings.mavenHomeSelection == MavenHomeSelection::Wrapper ||
        settings.mavenHomeSelection == MavenHomeSelection::Automatic) {
        for (const auto& wrapper : wrapperCandidates) {
            const auto path = pathUtf8(wrapper);
            if (locator_.isExecutable(path)) return path;
        }
        if (settings.mavenHomeSelection == MavenHomeSelection::Wrapper) return std::nullopt;
    }
    if (settings.mavenHomeSelection == MavenHomeSelection::Custom) {
        if (settings.mavenHomePath.empty()) return std::nullopt;
        return locator_.mavenExecutableForHomePath(settings.mavenHomePath);
    }
    return locator_.systemMavenExecutable();
}

std::optional<std::string> ProjectRuntimeService::javaLanguageServerExecutable() const {
    return locator_.javaLanguageServerExecutable();
}

std::map<std::string, std::string> ProjectRuntimeService::environment(
    const ProjectRuntimeSettings& settings,
    RuntimeProcessKind processKind,
    std::string overridePath) const {
    auto result = locator_.environment();
    const auto home = processKind == RuntimeProcessKind::Maven
        ? mavenJavaHome(settings, std::move(overridePath))
        : javaHome(settings, std::move(overridePath));
    if (!home) return result;
    const auto javaHomeEntry = findEnvironment(result, "JAVA_HOME");
    if (javaHomeEntry == result.end()) result["JAVA_HOME"] = *home;
    else result[javaHomeEntry->first] = *home;
    const auto javaBin = pathUtf8(pathFromUtf8(*home) / "bin");
    const auto pathEntry = findEnvironment(result, "PATH");
    const auto pathKey = pathEntry == result.end() ? std::string("PATH") : pathEntry->first;
    auto& path = result[pathKey];
    if (path.empty()) path = javaBin;
    else if (path.find(javaBin) != 0) {
#ifdef _WIN32
        path = javaBin + ";" + path;
#else
        path = javaBin + ":" + path;
#endif
    }
    return result;
}

std::string ProjectRuntimeService::normalize(std::string value) {
    value = trim(std::move(value));
    if (value.empty()) return {};
    return pathUtf8(pathFromUtf8(value).lexically_normal());
}

std::string ProjectRuntimeService::pathUtf8(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::filesystem::path ProjectRuntimeService::pathFromUtf8(const std::string& path) {
    const auto* data = reinterpret_cast<const char8_t*>(path.data());
    return std::filesystem::path(std::u8string(data, data + path.size()));
}

std::optional<std::string> ProjectRuntimeService::firstValidJavaHome(
    const std::vector<std::string>& candidates) const {
    for (const auto& candidate : candidates) {
        const auto normalized = normalize(candidate);
        if (normalized.empty()) continue;
        if (const auto home = locator_.validJavaHome(normalized)) return home;
    }
    return std::nullopt;
}

} // namespace lithe::windows::app
