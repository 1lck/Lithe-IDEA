#pragma once

#include "ports.h"

#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

enum class RuntimeProcessKind {
    Java,
    Maven,
};

enum class MavenHomeSelection {
    Automatic,
    Wrapper,
    Custom,
};

struct ProjectRuntimeSettings {
    std::string javaHomePath;
    MavenHomeSelection mavenHomeSelection = MavenHomeSelection::Automatic;
    std::string mavenHomePath;
    std::string mavenJavaHomePath;
};

class ProjectRuntimeService final {
public:
    explicit ProjectRuntimeService(RuntimeLocator& locator);

    RuntimeDiscoveryResult discover() const;
    std::optional<std::string> javaHome(
        const ProjectRuntimeSettings& settings,
        std::string overridePath = {}) const;
    std::optional<std::string> mavenJavaHome(
        const ProjectRuntimeSettings& settings,
        std::string overridePath = {}) const;
    std::optional<std::string> javaExecutable(
        const ProjectRuntimeSettings& settings,
        std::string overridePath = {}) const;
    std::optional<std::string> jdbExecutable(
        const ProjectRuntimeSettings& settings,
        RuntimeProcessKind processKind = RuntimeProcessKind::Java,
        std::string overridePath = {}) const;
    std::optional<std::string> mavenExecutable(
        const std::filesystem::path& projectRoot,
        const ProjectRuntimeSettings& settings) const;
    std::optional<std::string> javaLanguageServerExecutable() const;
    std::map<std::string, std::string> environment(
        const ProjectRuntimeSettings& settings,
        RuntimeProcessKind processKind,
        std::string overridePath = {}) const;

private:
    RuntimeLocator& locator_;

    static std::string normalize(std::string value);
    static std::string pathUtf8(const std::filesystem::path& path);
    static std::filesystem::path pathFromUtf8(const std::string& path);
    std::optional<std::string> firstValidJavaHome(
        const std::vector<std::string>& candidates) const;
};

} // namespace lithe::windows::app
