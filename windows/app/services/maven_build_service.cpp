#include "maven_build_service.h"

#include <algorithm>
#include <atomic>

namespace lithe::windows::app {
namespace {

std::string pathUtf8(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::string operationID() {
    static std::atomic<std::uint64_t> sequence{0};
    return "windows-maven-" + std::to_string(++sequence);
}

} // namespace

MavenBuildService::MavenBuildService(ProjectRuntimeService& runtime,
                                     ProcessRunner& runner)
    : runtime_(runtime), runner_(runner) {}

std::optional<ProcessRequest> MavenBuildService::makeRequest(
    const MavenBuildRequest& request,
    std::string& error) const {
    if (request.projectRoot.empty()) {
        error = "Maven project root is empty";
        return std::nullopt;
    }
    if (request.phase.empty()) {
        error = "Maven phase is empty";
        return std::nullopt;
    }
    const auto executable = runtime_.mavenExecutable(request.projectRoot, request.runtime);
    if (!executable) {
        error = "No Maven executable was found";
        return std::nullopt;
    }
    ProcessRequest process;
    process.operationID = operationID();
    process.executablePath = *executable;
    process.workingDirectory = pathUtf8(request.projectRoot);
    process.arguments = {"-B", "-ntp"};
    if (!request.modulePaths.empty()) {
        std::vector<std::string> modules = request.modulePaths;
        process.arguments.emplace_back("-pl");
        std::string joined;
        for (const auto& module : modules) {
            if (!joined.empty()) joined.push_back(',');
            joined += module;
        }
        process.arguments.push_back(std::move(joined));
    }
    if (!request.activeProfiles.empty()) {
        auto profiles = request.activeProfiles;
        std::sort(profiles.begin(), profiles.end());
        process.arguments.emplace_back("-P");
        std::string joined;
        for (const auto& profile : profiles) {
            if (!joined.empty()) joined.push_back(',');
            joined += profile;
        }
        process.arguments.push_back(std::move(joined));
    }
    process.arguments.push_back(request.phase);
    process.environment = runtime_.environment(request.runtime, RuntimeProcessKind::Maven);
    process.timeoutMilliseconds = request.timeoutMilliseconds;
    return process;
}

ProcessResult MavenBuildService::run(const MavenBuildRequest& request) const {
    std::string error;
    const auto process = makeRequest(request, error);
    if (!process) return ProcessResult{error, 1, false};
    return runner_.run(*process);
}

} // namespace lithe::windows::app
