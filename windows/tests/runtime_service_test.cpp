#include "maven_build_service.h"

#include <cassert>
#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace {

std::string pathText(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::string javaBinary(const std::string& home, const char* name) {
    return pathText(std::filesystem::path(home) / "bin" /
#ifdef _WIN32
                    (std::string(name) + ".exe")
#else
                    name
#endif
    );
}

std::string pathSeparator() {
#ifdef _WIN32
    return ";";
#else
    return ":";
#endif
}

class FakeRuntimeLocator final : public lithe::windows::RuntimeLocator {
public:
    std::map<std::string, std::string> environmentValues;
    lithe::windows::RuntimeDiscoveryResult discovery;
    std::set<std::string> validHomes;
    std::set<std::string> executablePaths;
    std::map<std::string, std::string> mavenByHome;
    std::optional<std::string> systemMaven;
    std::optional<std::string> systemJdb;
    std::optional<std::string> languageServer;

    std::map<std::string, std::string> environment() const override {
        return environmentValues;
    }

    lithe::windows::RuntimeDiscoveryResult discover() const override {
        return discovery;
    }

    std::optional<std::string> validJavaHome(const std::string& path) const override {
        return validHomes.contains(path) ? std::optional(path) : std::nullopt;
    }

    bool isExecutable(const std::string& path) const override {
        return executablePaths.contains(path);
    }

    std::optional<std::string> systemMavenExecutable() const override {
        return systemMaven;
    }

    std::optional<std::string> mavenExecutableForHomePath(
        const std::string& path) const override {
        const auto found = mavenByHome.find(path);
        return found == mavenByHome.end()
            ? std::nullopt
            : std::optional<std::string>(found->second);
    }

    std::optional<std::string> systemJDBExecutable() const override {
        return systemJdb;
    }

    std::optional<std::string> javaLanguageServerExecutable() const override {
        return languageServer;
    }
};

class FakeProcessRunner final : public lithe::windows::ProcessRunner {
public:
    lithe::windows::ProcessRequest lastRequest;

    lithe::windows::ProcessResult run(
        const lithe::windows::ProcessRequest& request) override {
        lastRequest = request;
        return {"build output", 0, true};
    }
};

} // namespace

int main() {
    FakeRuntimeLocator locator;
    locator.environmentValues = {
        {"JAVA_HOME", "C:/env-jdk"},
#ifdef _WIN32
        {"Path", "C:/Windows/System32"},
#else
        {"PATH", "C:/Windows/System32"},
#endif
    };
    locator.validHomes = {
        "C:/override-jdk", "C:/configured-jdk", "C:/env-jdk", "C:/maven-jdk",
    };
    locator.systemMaven = "C:/tools/mvn.cmd";
    locator.systemJdb = "C:/tools/jdb.exe";

    lithe::windows::app::ProjectRuntimeService runtime(locator);
    lithe::windows::app::ProjectRuntimeSettings settings;
    settings.javaHomePath = "C:/configured-jdk";
    settings.mavenJavaHomePath = "C:/maven-jdk";

    assert(runtime.javaHome(settings, "  C:/override-jdk  ") == "C:/override-jdk");
    assert(runtime.mavenJavaHome(settings) == "C:/maven-jdk");

    locator.executablePaths.insert(javaBinary("C:/override-jdk", "java"));
    locator.executablePaths.insert(javaBinary("C:/maven-jdk", "jdb"));
    assert(runtime.javaExecutable(settings, "C:/override-jdk") ==
           javaBinary("C:/override-jdk", "java"));
    assert(runtime.jdbExecutable(settings, lithe::windows::app::RuntimeProcessKind::Maven) ==
           javaBinary("C:/maven-jdk", "jdb"));

    const auto javaEnvironment = runtime.environment(
        settings, lithe::windows::app::RuntimeProcessKind::Java, "C:/override-jdk");
    assert(javaEnvironment.at("JAVA_HOME") == "C:/override-jdk");
    const auto path = javaEnvironment.find("PATH") != javaEnvironment.end()
        ? javaEnvironment.at("PATH")
        : javaEnvironment.at("Path");
    assert(path == pathText(std::filesystem::path("C:/override-jdk") / "bin") +
           pathSeparator() + "C:/Windows/System32");

    const auto projectRoot = std::filesystem::path("C:/project");
    const auto wrapper = pathText(projectRoot /
#ifdef _WIN32
                                  "mvnw.cmd"
#else
                                  "mvnw"
#endif
    );
    locator.executablePaths.insert(wrapper);
    lithe::windows::app::ProjectRuntimeSettings automatic = settings;
    automatic.mavenHomeSelection = lithe::windows::app::MavenHomeSelection::Automatic;
    assert(runtime.mavenExecutable(projectRoot, automatic) == wrapper);

    locator.executablePaths.erase(wrapper);
    automatic.mavenHomeSelection = lithe::windows::app::MavenHomeSelection::Automatic;
    assert(runtime.mavenExecutable(projectRoot, automatic) == locator.systemMaven);

    lithe::windows::app::ProjectRuntimeSettings custom = settings;
    custom.mavenHomeSelection = lithe::windows::app::MavenHomeSelection::Custom;
    custom.mavenHomePath = "C:/custom-maven";
    locator.mavenByHome[custom.mavenHomePath] = "C:/custom-maven/bin/mvn.cmd";
    assert(runtime.mavenExecutable(projectRoot, custom) ==
           locator.mavenByHome[custom.mavenHomePath]);

    lithe::windows::app::ProjectRuntimeSettings wrapperOnly = settings;
    wrapperOnly.mavenHomeSelection = lithe::windows::app::MavenHomeSelection::Wrapper;
    assert(!runtime.mavenExecutable(projectRoot, wrapperOnly));

    FakeProcessRunner runner;
    lithe::windows::app::MavenBuildService maven(runtime, runner);
    lithe::windows::app::MavenBuildRequest buildRequest;
    buildRequest.projectRoot = projectRoot;
    buildRequest.phase = "package";
    buildRequest.modulePaths = {"module-b", "module-a"};
    buildRequest.activeProfiles = {"zeta", "alpha"};
    buildRequest.runtime = custom;
    buildRequest.timeoutMilliseconds = 9000;

    std::string error;
    const auto process = maven.makeRequest(buildRequest, error);
    assert(process && error.empty());
    assert(process->executablePath == locator.mavenByHome[custom.mavenHomePath]);
    assert(process->workingDirectory == pathText(projectRoot));
    assert((process->arguments == std::vector<std::string>{
        "-B", "-ntp", "-pl", "module-b,module-a", "-P", "alpha,zeta", "package"}));
    assert(process->environment.at("JAVA_HOME") == "C:/maven-jdk");
    assert(process->timeoutMilliseconds == 9000);

    const auto result = maven.run(buildRequest);
    assert(result.started && result.exitCode == 0);
    assert(runner.lastRequest.operationID.rfind("windows-maven-", 0) == 0);

    lithe::windows::app::MavenBuildRequest invalid = buildRequest;
    invalid.phase.clear();
    assert(!maven.makeRequest(invalid, error));
    assert(error == "Maven phase is empty");
    invalid = buildRequest;
    invalid.runtime.mavenHomePath = "C:/missing-maven";
    invalid.runtime.mavenHomeSelection = lithe::windows::app::MavenHomeSelection::Custom;
    assert(!maven.makeRequest(invalid, error));
    assert(error == "No Maven executable was found");
    return 0;
}
