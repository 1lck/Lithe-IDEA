#pragma once

#include "core_dto.h"
#include "project_runtime_service.h"

#include <cstdint>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::app {

enum class JavaRunConfigurationKind {
    CurrentFile,
    SpringBoot,
    MavenModule,
};

struct JavaRunOptions {
    std::string javaHomePath;
    std::string workingDirectoryPath;
    std::string vmArguments;
    std::string programArguments;
    std::vector<std::string> activeProfiles;
};

struct JavaRunProject {
    std::filesystem::path root;
    std::vector<std::filesystem::path> files;
    std::optional<MavenScanDto> maven;
    std::vector<JavaRunConfigurationDto> configurations;
    std::map<std::string, JavaRunOptions> optionsByConfigurationID;
};

struct JavaRunPortConflict {
    std::uint16_t port = 0;
    std::vector<std::string> configurationNames;
};

class JavaRunService final {
public:
    JavaRunService(ProjectRuntimeService& runtime, FileStorage& storage);

    void setProject(JavaRunProject project);
    void setRuntimeSettings(ProjectRuntimeSettings settings);
    const JavaRunProject& project() const;

    std::optional<ProcessRequest> makeRequest(
        const JavaRunConfigurationDto& configuration,
        const JavaRunOptions& options,
        std::optional<std::filesystem::path> currentFile,
        std::string& error) const;

    std::vector<JavaRunPortConflict> portConflicts() const;

    static std::vector<std::string> parseArguments(std::string_view input);
    static std::optional<std::uint16_t> configuredPort(std::string_view input);

private:
    ProjectRuntimeService& runtime_;
    FileStorage& storage_;
    ProjectRuntimeSettings runtimeSettings_;
    JavaRunProject project_;

    static std::string pathUtf8(const std::filesystem::path& path);
    static std::filesystem::path pathFromUtf8(const std::string& path);
    static std::string operationID();
    static std::optional<JavaRunConfigurationKind> configurationKind(
        std::string_view value);
    static bool isInside(const std::filesystem::path& path,
                         const std::filesystem::path& directory);
    static std::vector<MavenModuleDto> flattenModules(
        const std::vector<MavenModuleDto>& modules);
    static std::optional<std::uint16_t> portFromConfigurationFiles(
        std::string_view content,
        std::string_view extension);

    std::filesystem::path moduleDirectory(const std::string& relativePath) const;
    std::filesystem::path classPathFor(const std::filesystem::path& file) const;
    std::filesystem::path resolvedWorkingDirectory(
        const std::string& requested,
        const std::filesystem::path& fallback) const;
    std::optional<std::uint16_t> configuredPortFor(
        const JavaRunConfigurationDto& configuration) const;
    std::map<std::string, std::string> environment(
        RuntimeProcessKind kind,
        const std::string& javaHomeOverride) const;
};

} // namespace lithe::windows::app
