#include "java_run_service.h"

#include <cassert>
#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace {

std::string pathText(const std::filesystem::path& path) {
    const auto value = path.generic_u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::string javaBinary(const std::string& home) {
    return pathText(std::filesystem::path(home) / "bin" /
#ifdef _WIN32
                    "java.exe"
#else
                    "java"
#endif
    );
}

class FakeRuntimeLocator final : public lithe::windows::RuntimeLocator {
public:
    std::map<std::string, std::string> environmentValues;
    std::set<std::string> validHomes;
    std::set<std::string> executablePaths;
    std::optional<std::string> systemMaven;

    std::map<std::string, std::string> environment() const override {
        return environmentValues;
    }

    lithe::windows::RuntimeDiscoveryResult discover() const override {
        return {};
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
        const std::string&) const override {
        return std::nullopt;
    }

    std::optional<std::string> systemJDBExecutable() const override {
        return std::nullopt;
    }

    std::optional<std::string> javaLanguageServerExecutable() const override {
        return std::nullopt;
    }
};

class FakeFileStorage final : public lithe::windows::FileStorage {
public:
    std::map<std::string, lithe::windows::FileMetadata> metadataValues;
    std::map<std::string, std::vector<std::uint8_t>> dataValues;

    std::string homeDirectory() const override { return {}; }
    std::string cacheDirectory() const override { return {}; }
    std::string applicationSupportDirectory() const override { return {}; }

    std::optional<lithe::windows::FileMetadata> metadata(
        const std::string& path) const override {
        const auto found = metadataValues.find(path);
        return found == metadataValues.end()
            ? std::nullopt
            : std::optional(found->second);
    }

    bool fileExists(const std::string& path) const override {
        return metadata(path).has_value();
    }

    bool isExecutable(const std::string&) const override { return false; }
    std::vector<std::string> listDirectory(const std::string&) const override { return {}; }
    std::optional<std::vector<std::uint8_t>> readData(
        const std::string& path, std::string& error) const override {
        const auto found = dataValues.find(path);
        if (found == dataValues.end()) {
            error = "missing test file";
            return std::nullopt;
        }
        return found->second;
    }

    bool writeData(const std::string&, const std::vector<std::uint8_t>&,
                   std::string&) override { return false; }
    bool createDirectory(const std::string&, bool, std::string&) override { return false; }
    bool removeItem(const std::string&, std::string&) override { return false; }
    bool moveItem(const std::string&, const std::string&, std::string&) override { return false; }
};

void addDirectory(FakeFileStorage& storage, const std::filesystem::path& path) {
    lithe::windows::FileMetadata metadata;
    metadata.isDirectory = true;
    storage.metadataValues[pathText(path)] = metadata;
}

void addFile(FakeFileStorage& storage, const std::filesystem::path& path,
             const std::string& content) {
    lithe::windows::FileMetadata metadata;
    metadata.isRegularFile = true;
    metadata.byteCount = content.size();
    storage.metadataValues[pathText(path)] = metadata;
    auto& data = storage.dataValues[pathText(path)];
    data.assign(reinterpret_cast<const std::uint8_t*>(content.data()),
                reinterpret_cast<const std::uint8_t*>(content.data()) + content.size());
}

} // namespace

int main() {
    const auto root = std::filesystem::temp_directory_path() / "lithe-java-run-test";
    const auto serviceRoot = root / "service";
    const auto source = serviceRoot / "src" / "Main.java";
    const auto classes = serviceRoot / "target" / "classes";
    const auto javaHome = root / "jdk-21";

    FakeRuntimeLocator locator;
    locator.environmentValues = {
        {"JAVA_HOME", pathText(javaHome)},
        {"PATH", "C:/Windows/System32"},
    };
    locator.validHomes.insert(pathText(javaHome));
    locator.executablePaths.insert(javaBinary(pathText(javaHome)));
    const auto wrapper = root /
#ifdef _WIN32
        "mvnw.cmd";
#else
        "mvnw";
#endif
    locator.executablePaths.insert(pathText(wrapper));

    FakeFileStorage storage;
    addDirectory(storage, serviceRoot);
    addDirectory(storage, classes);
    addFile(storage, source, "class Main {}\n");
    const auto application = serviceRoot / "src" / "main" / "resources" /
                             "application.yml";
    addFile(storage, application, "server:\n  port: 9090\n");

    lithe::windows::app::ProjectRuntimeService runtime(locator);
    lithe::windows::app::JavaRunService service(runtime, storage);

    lithe::windows::MavenModuleDto module{
        "service", std::string("com.example"), "service", std::string("1.0"), "jar", {}};
    lithe::windows::MavenScanDto maven{
        std::string("com.example"), "root", std::string("1.0"), "pom", {module}, {}, true};
    lithe::windows::JavaRunConfigurationDto current{
        "current-file", "Current File", "currentFile", std::nullopt, std::nullopt};
    lithe::windows::JavaRunConfigurationDto spring{
        "spring", "Service", "springBoot", std::string("service"),
        std::string("com.example.Main")};
    lithe::windows::JavaRunConfigurationDto moduleRun{
        "module", "Service Module", "mavenModule", std::string("service"),
        std::string("com.example.Main")};

    lithe::windows::app::JavaRunProject project;
    project.root = root;
    project.files = {source, application};
    project.maven = maven;
    project.configurations = {current, spring, moduleRun};
    project.optionsByConfigurationID[moduleRun.id] = {
        {}, {}, {}, "--server.port=9090", {}};
    service.setProject(project);

    assert((lithe::windows::app::JavaRunService::parseArguments(
        "-Dname=\"hello world\" 'two words' tail") ==
        std::vector<std::string>{"-Dname=hello world", "two words", "tail"}));
    assert(lithe::windows::app::JavaRunService::configuredPort(
        "-Dserver.port 8123") == 8123);

    std::string error;
    lithe::windows::app::JavaRunOptions currentOptions;
    currentOptions.vmArguments = "-Dhello=\"world value\"";
    currentOptions.programArguments = "one \"two words\"";
    currentOptions.workingDirectoryPath = "service";
    const auto currentRequest = service.makeRequest(current, currentOptions, source, error);
    assert(currentRequest && error.empty());
    assert(currentRequest->executablePath == javaBinary(pathText(javaHome)));
    assert((currentRequest->arguments == std::vector<std::string>{
        "-Dhello=world value", "--class-path", pathText(classes), pathText(source),
        "one", "two words"}));
    assert(currentRequest->workingDirectory == pathText(serviceRoot));
    assert(currentRequest->environment.at("JAVA_HOME") == pathText(javaHome));

    lithe::windows::app::JavaRunOptions springOptions;
    springOptions.activeProfiles = {"prod", "dev"};
    springOptions.vmArguments = "-Xmx512m";
    springOptions.programArguments = "--debug";
    const auto springRequest = service.makeRequest(spring, springOptions, std::nullopt, error);
    assert(springRequest && error.empty());
    assert((springRequest->arguments == std::vector<std::string>{
        "-B", "-ntp", "-pl", "service", "-P", "dev,prod",
        "-Dspring-boot.run.main-class=com.example.Main",
        "-Dspring-boot.run.jvmArguments=-Xmx512m",
        "-Dspring-boot.run.arguments=--debug", "spring-boot:run"}));
    assert(springRequest->workingDirectory == pathText(serviceRoot));
    assert(springRequest->executablePath == pathText(wrapper));

    const auto conflicts = service.portConflicts();
    assert(conflicts.empty());

    auto second = moduleRun;
    second.id = "module-2";
    second.name = "Another Module";
    auto projectWithConflict = project;
    projectWithConflict.configurations.push_back(second);
    projectWithConflict.optionsByConfigurationID[second.id] = {
        {}, {}, {}, "--server.port=9090", {}};
    service.setProject(std::move(projectWithConflict));
    const auto conflictPair = service.portConflicts();
    assert(conflictPair.size() == 1);
    const std::vector<std::string> expectedNames = {"Another Module", "Service Module"};
    assert((conflictPair[0].configurationNames == expectedNames));

    auto bad = currentOptions;
    const auto badRequest = service.makeRequest(current, bad,
        root / "README.md", error);
    assert(!badRequest);
    assert(error == "Current File must be a Java source file");
    return 0;
}
