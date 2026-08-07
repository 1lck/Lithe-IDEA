#include "java_run_service.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <fstream>
#include <sstream>
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

bool startsWith(std::string_view value, std::string_view prefix) {
    return value.size() >= prefix.size() && value.substr(0, prefix.size()) == prefix;
}

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](char character) {
        return static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    });
    return value;
}

std::optional<std::uint16_t> validPort(std::string value) {
    value = trim(std::move(value));
    if (value.empty() || !std::all_of(value.begin(), value.end(), [](char character) {
            return std::isdigit(static_cast<unsigned char>(character)) != 0;
        })) {
        return std::nullopt;
    }
    try {
        const auto parsed = std::stoul(value);
        if (parsed == 0 || parsed > 65535) return std::nullopt;
        return static_cast<std::uint16_t>(parsed);
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<std::string> environmentValue(
    const std::map<std::string, std::string>& values,
    std::string_view key) {
    const auto found = std::find_if(values.begin(), values.end(), [&](const auto& entry) {
        if (entry.first.size() != key.size()) return false;
        for (std::size_t index = 0; index < key.size(); ++index) {
            if (std::tolower(static_cast<unsigned char>(entry.first[index])) !=
                std::tolower(static_cast<unsigned char>(key[index]))) return false;
        }
        return true;
    });
    return found == values.end() ? std::nullopt : std::optional(found->second);
}

} // namespace

JavaRunService::JavaRunService(ProjectRuntimeService& runtime, FileStorage& storage)
    : runtime_(runtime), storage_(storage) {}

void JavaRunService::setProject(JavaRunProject project) {
    project_ = std::move(project);
    project_.root = project_.root.lexically_normal();
}

void JavaRunService::setRuntimeSettings(ProjectRuntimeSettings settings) {
    runtimeSettings_ = std::move(settings);
}

const JavaRunProject& JavaRunService::project() const {
    return project_;
}

std::optional<ProcessRequest> JavaRunService::makeRequest(
    const JavaRunConfigurationDto& configuration,
    const JavaRunOptions& options,
    std::optional<std::filesystem::path> currentFile,
    std::string& error) const {
    if (project_.root.empty()) {
        error = "Java project root is empty";
        return std::nullopt;
    }
    const auto kind = configurationKind(configuration.kind);
    if (!kind) {
        error = "Unknown Java run configuration kind: " + configuration.kind;
        return std::nullopt;
    }

    ProcessRequest process;
    process.operationID = operationID();
    std::filesystem::path fallbackDirectory = project_.root;
    if (*kind == JavaRunConfigurationKind::CurrentFile) {
        if (!currentFile) {
            error = "Select a Java file before running Current File";
            return std::nullopt;
        }
        auto source = currentFile->lexically_normal();
        if (!source.is_absolute()) source = project_.root / source;
        source = source.lexically_normal();
        if (lower(pathUtf8(source.extension())) != ".java") {
            error = "Current File must be a Java source file";
            return std::nullopt;
        }
        if (!isInside(source, project_.root)) {
            error = "Current Java file is outside the project root";
            return std::nullopt;
        }
        const auto executable = runtime_.javaExecutable(runtimeSettings_, options.javaHomePath);
        if (!executable) {
            error = "No Java runtime was found";
            return std::nullopt;
        }
        process.executablePath = *executable;
        process.arguments = parseArguments(options.vmArguments);
        const auto classPath = classPathFor(source);
        if (!classPath.empty()) {
            process.arguments.push_back("--class-path");
            process.arguments.push_back(pathUtf8(classPath));
        }
        process.arguments.push_back(pathUtf8(source));
        const auto programArguments = parseArguments(options.programArguments);
        process.arguments.insert(process.arguments.end(), programArguments.begin(),
                                 programArguments.end());
        fallbackDirectory = source.parent_path();
        process.environment = environment(RuntimeProcessKind::Java, options.javaHomePath);
    } else {
        if (!project_.maven) {
            error = "No Maven project is available for this run configuration";
            return std::nullopt;
        }
        const auto executable = runtime_.mavenExecutable(project_.root, runtimeSettings_);
        if (!executable) {
            error = "No Maven executable was found";
            return std::nullopt;
        }
        process.executablePath = *executable;
        process.arguments = {"-B", "-ntp"};
        if (configuration.modulePath) {
            process.arguments.push_back("-pl");
            process.arguments.push_back(*configuration.modulePath);
            fallbackDirectory = moduleDirectory(*configuration.modulePath);
        }
        auto profiles = options.activeProfiles;
        std::sort(profiles.begin(), profiles.end());
        profiles.erase(std::remove_if(profiles.begin(), profiles.end(),
                                      [](const auto& profile) { return trim(profile).empty(); }),
                       profiles.end());
        if (!profiles.empty()) {
            process.arguments.push_back("-P");
            std::string joined;
            for (const auto& profile : profiles) {
                if (!joined.empty()) joined.push_back(',');
                joined += profile;
            }
            process.arguments.push_back(std::move(joined));
        }
        if (configuration.mainClass) {
            process.arguments.push_back("-Dspring-boot.run.main-class=" +
                                       *configuration.mainClass);
        }
        const auto vmArguments = trim(options.vmArguments);
        if (!vmArguments.empty()) {
            process.arguments.push_back("-Dspring-boot.run.jvmArguments=" + vmArguments);
        }
        const auto programArguments = trim(options.programArguments);
        if (!programArguments.empty()) {
            process.arguments.push_back("-Dspring-boot.run.arguments=" + programArguments);
        }
        process.arguments.push_back("spring-boot:run");
        process.environment = environment(RuntimeProcessKind::Maven, options.javaHomePath);
    }

    process.workingDirectory = pathUtf8(
        resolvedWorkingDirectory(options.workingDirectoryPath, fallbackDirectory));
    return process;
}

std::vector<JavaRunPortConflict> JavaRunService::portConflicts() const {
    std::map<std::uint16_t, std::vector<std::string>> byPort;
    for (const auto& configuration : project_.configurations) {
        if (configuration.kind != "mavenModule") continue;
        byPort[configuredPortFor(configuration).value_or(8080)].push_back(
            configuration.name);
    }

    std::vector<JavaRunPortConflict> result;
    for (auto& [port, names] : byPort) {
        if (names.size() < 2) continue;
        std::sort(names.begin(), names.end());
        result.push_back({port, std::move(names)});
    }
    return result;
}

std::vector<std::string> JavaRunService::parseArguments(std::string_view input) {
    std::vector<std::string> result;
    std::string current;
    char quote = '\0';
    bool escaped = false;
    for (const char character : input) {
        if (escaped) {
            current.push_back(character);
            escaped = false;
            continue;
        }
        if (character == '\\' && quote != '\'') {
            escaped = true;
            continue;
        }
        if (character == '\'' || character == '"') {
            if (quote == character) quote = '\0';
            else if (quote == '\0') quote = character;
            else current.push_back(character);
            continue;
        }
        if (std::isspace(static_cast<unsigned char>(character)) && quote == '\0') {
            if (!current.empty()) {
                result.push_back(std::move(current));
                current.clear();
            }
            continue;
        }
        current.push_back(character);
    }
    if (escaped) current.push_back('\\');
    if (!current.empty()) result.push_back(std::move(current));
    return result;
}

std::optional<std::uint16_t> JavaRunService::configuredPort(std::string_view input) {
    const auto tokens = parseArguments(input);
    const std::vector<std::string> keys = {
        "--server.port=", "-Dserver.port=", "--server.port", "-Dserver.port"};
    for (std::size_t index = 0; index < tokens.size(); ++index) {
        for (const auto& key : keys) {
            if (!startsWith(tokens[index], key)) continue;
            auto value = tokens[index].substr(key.size());
            if (value.empty() && index + 1 < tokens.size()) value = tokens[index + 1];
            if (const auto port = validPort(value)) return port;
        }
    }
    return std::nullopt;
}

std::string JavaRunService::pathUtf8(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::filesystem::path JavaRunService::pathFromUtf8(const std::string& path) {
    const auto* data = reinterpret_cast<const char8_t*>(path.data());
    return std::filesystem::path(std::u8string(data, data + path.size()));
}

std::string JavaRunService::operationID() {
    static std::atomic<std::uint64_t> sequence{0};
    return "windows-java-run-" + std::to_string(++sequence);
}

std::optional<JavaRunConfigurationKind> JavaRunService::configurationKind(
    std::string_view value) {
    if (value == "currentFile") return JavaRunConfigurationKind::CurrentFile;
    if (value == "springBoot") return JavaRunConfigurationKind::SpringBoot;
    if (value == "mavenModule") return JavaRunConfigurationKind::MavenModule;
    return std::nullopt;
}

bool JavaRunService::isInside(const std::filesystem::path& path,
                              const std::filesystem::path& directory) {
    const auto relative = path.lexically_normal().lexically_relative(
        directory.lexically_normal());
    if (relative.empty()) return false;
    for (const auto& component : relative) {
        if (component == "..") return false;
    }
    return true;
}

std::vector<MavenModuleDto> JavaRunService::flattenModules(
    const std::vector<MavenModuleDto>& modules) {
    std::vector<MavenModuleDto> result;
    for (const auto& module : modules) {
        result.push_back(module);
        const auto nested = flattenModules(module.modules);
        result.insert(result.end(), nested.begin(), nested.end());
    }
    return result;
}

std::optional<std::uint16_t> JavaRunService::portFromConfigurationFiles(
    std::string_view content,
    std::string_view extension) {
    const auto normalizedExtension = lower(std::string(extension));
    std::istringstream lines{std::string(content)};
    std::string line;
    while (std::getline(lines, line)) {
        auto value = trim(line);
        if (normalizedExtension == ".properties" && startsWith(value, "server.port")) {
            const auto separator = value.find('=');
            if (separator != std::string::npos) {
                if (const auto port = validPort(value.substr(separator + 1))) return port;
            }
        }
        if ((normalizedExtension == ".yml" || normalizedExtension == ".yaml") &&
            startsWith(value, "server.port:")) {
            if (const auto port = validPort(value.substr(std::string("server.port:").size()))) {
                return port;
            }
        }
    }
    return std::nullopt;
}

std::filesystem::path JavaRunService::moduleDirectory(const std::string& relativePath) const {
    if (!project_.maven) return project_.root;
    for (const auto& module : flattenModules(project_.maven->modules)) {
        if (module.relativePath == relativePath) {
            return (project_.root / pathFromUtf8(relativePath)).lexically_normal();
        }
    }
    return project_.root;
}

std::filesystem::path JavaRunService::classPathFor(const std::filesystem::path& file) const {
    std::vector<std::filesystem::path> roots;
    if (project_.maven) {
        for (const auto& module : flattenModules(project_.maven->modules)) {
            const auto root = (project_.root / pathFromUtf8(module.relativePath)).lexically_normal();
            if (isInside(file, root)) roots.push_back(root);
        }
    }
    roots.push_back(project_.root);
    std::sort(roots.begin(), roots.end(), [](const auto& left, const auto& right) {
        return left.native().size() > right.native().size();
    });
    for (const auto& root : roots) {
        const auto classes = (root / "target" / "classes").lexically_normal();
        const auto metadata = storage_.metadata(pathUtf8(classes));
        if (metadata && metadata->isDirectory) return classes;
    }
    return {};
}

std::filesystem::path JavaRunService::resolvedWorkingDirectory(
    const std::string& requested,
    const std::filesystem::path& fallback) const {
    const auto value = trim(requested);
    if (value.empty()) return fallback.lexically_normal();
    std::filesystem::path candidate;
    if (value == "~" || startsWith(value, "~/") || startsWith(value, "~\\")) {
        const auto environment = runtime_.environment(runtimeSettings_, RuntimeProcessKind::Java);
        const auto home = environmentValue(environment, "USERPROFILE").value_or(
            environmentValue(environment, "HOME").value_or(std::string{}));
        if (!home.empty()) candidate = pathFromUtf8(home) / value.substr(2);
    } else {
        candidate = pathFromUtf8(value);
        if (!candidate.is_absolute()) candidate = project_.root / candidate;
    }
    if (candidate.empty()) return fallback.lexically_normal();
    candidate = candidate.lexically_normal();
    const auto metadata = storage_.metadata(pathUtf8(candidate));
    return metadata && metadata->isDirectory ? candidate : fallback.lexically_normal();
}

std::map<std::string, std::string> JavaRunService::environment(
    RuntimeProcessKind kind,
    const std::string& javaHomeOverride) const {
    return runtime_.environment(runtimeSettings_, kind, javaHomeOverride);
}

std::optional<std::uint16_t> JavaRunService::configuredPortFor(
    const JavaRunConfigurationDto& configuration) const {
    const auto options = project_.optionsByConfigurationID.find(configuration.id);
    if (options != project_.optionsByConfigurationID.end()) {
        if (const auto port = configuredPort(options->second.programArguments)) return port;
        if (const auto port = configuredPort(options->second.vmArguments)) return port;
    }

    const auto moduleRoot = configuration.modulePath
        ? moduleDirectory(*configuration.modulePath)
        : project_.root;
    for (const auto& file : project_.files) {
        if (!isInside(file, moduleRoot)) continue;
        const auto name = lower(pathUtf8(file.filename()));
        const bool isApplicationFile = name == "application.properties" ||
            name == "application.yml" || name == "application.yaml" ||
            (startsWith(name, "application-") &&
             (name.ends_with(".properties") || name.ends_with(".yml") ||
              name.ends_with(".yaml")));
        if (!isApplicationFile) continue;
        std::string readError;
        const auto data = storage_.readData(pathUtf8(file), readError);
        if (!data) continue;
        const std::string content(reinterpret_cast<const char*>(data->data()), data->size());
        if (const auto port = portFromConfigurationFiles(content,
                                                          pathUtf8(file.extension()))) {
            return port;
        }
    }
    return std::nullopt;
}

} // namespace lithe::windows::app
