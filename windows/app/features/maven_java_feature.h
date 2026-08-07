#pragma once

#include "workbench_coordinator.h"

#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

struct MavenJavaFeatureState {
    std::optional<MavenScanResultDto> maven;
    std::optional<MavenDiagnosticsDto> diagnostics;
    std::optional<JavaRunConfigurationsDto> runConfigurations;
    std::optional<JavaCodeVisionDto> codeVision;
    std::optional<JavaClassNameDto> className;
    std::optional<JavaSourceDefinitionResultDto> sourceDefinition;
    std::optional<JavaServerPortDto> serverPort;
    std::optional<JavaStructureDto> structure;
    std::optional<CoreError> error;
    bool isLoadingMaven = false;
    bool isLoadingDiagnostics = false;
    bool isLoadingRunConfigurations = false;
    bool isLoadingCodeVision = false;
    bool isLoadingClassName = false;
    bool isLoadingSourceDefinition = false;
    bool isLoadingServerPort = false;
    bool isLoadingStructure = false;
};

class MavenJavaFeatureModel final {
public:
    using StateHandler = std::function<void(MavenJavaFeatureState)>;

    explicit MavenJavaFeatureModel(WorkbenchCoordinator& coordinator);

    void scanMaven(StateHandler handler = {});
    void parseMavenDiagnostics(std::string output, StateHandler handler = {});
    void loadRunConfigurations(std::vector<std::string> paths = {},
                               std::vector<std::string> modulePaths = {},
                               StateHandler handler = {});
    void loadCodeVision(std::string targetPath,
                        std::vector<std::string> paths = {},
                        StateHandler handler = {});
    void resolveClassName(std::string source,
                          std::string simpleName,
                          StateHandler handler = {});
    void findSourceDefinition(std::string source,
                              std::string declarationName,
                              std::optional<std::string> memberName = std::nullopt,
                              StateHandler handler = {});
    void findServerPort(std::string content,
                        std::string fileExtension,
                        StateHandler handler = {});
    void loadJavaStructure(std::string source,
                           std::vector<std::string> declarationSources = {},
                           StateHandler handler = {});
    void resetForWorkspace();
    MavenJavaFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    mutable std::mutex mutex_;
    MavenJavaFeatureState state_;

    void applyMaven(WorkspaceOperationResult result, StateHandler handler);
    void applyDiagnostics(WorkspaceOperationResult result, StateHandler handler);
    void applyRunConfigurations(WorkspaceOperationResult result, StateHandler handler);
    void applyCodeVision(WorkspaceOperationResult result, StateHandler handler);
    void applyClassName(WorkspaceOperationResult result, StateHandler handler);
    void applySourceDefinition(WorkspaceOperationResult result, StateHandler handler);
    void applyServerPort(WorkspaceOperationResult result, StateHandler handler);
    void applyStructure(WorkspaceOperationResult result, StateHandler handler);
};

} // namespace lithe::windows::app
