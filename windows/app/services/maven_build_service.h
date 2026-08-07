#pragma once

#include "project_runtime_service.h"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

struct MavenBuildRequest {
    std::filesystem::path projectRoot;
    std::string phase;
    std::vector<std::string> modulePaths;
    std::vector<std::string> activeProfiles;
    ProjectRuntimeSettings runtime;
    std::optional<std::uint64_t> timeoutMilliseconds;
};

class MavenBuildService final {
public:
    MavenBuildService(ProjectRuntimeService& runtime, ProcessRunner& runner);

    std::optional<ProcessRequest> makeRequest(const MavenBuildRequest& request,
                                               std::string& error) const;
    ProcessResult run(const MavenBuildRequest& request) const;

private:
    ProjectRuntimeService& runtime_;
    ProcessRunner& runner_;
};

} // namespace lithe::windows::app
