#include "maven_java_feature.h"

namespace lithe::windows::app {

MavenJavaFeatureModel::MavenJavaFeatureModel(WorkbenchCoordinator& coordinator)
    : coordinator_(coordinator) {}

void MavenJavaFeatureModel::scanMaven(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingMaven = true;
        state_.error.reset();
    }
    coordinator_.mavenScan([this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        applyMaven(std::move(result), std::move(handler));
    });
}

void MavenJavaFeatureModel::parseMavenDiagnostics(std::string output, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingDiagnostics = true;
        state_.error.reset();
    }
    coordinator_.mavenDiagnostics(std::move(output), [this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        applyDiagnostics(std::move(result), std::move(handler));
    });
}

void MavenJavaFeatureModel::loadRunConfigurations(std::vector<std::string> paths,
                                                  std::vector<std::string> modulePaths,
                                                  StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingRunConfigurations = true;
        state_.error.reset();
    }
    coordinator_.javaRunConfigurations(std::move(paths), std::move(modulePaths),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyRunConfigurations(std::move(result), std::move(handler));
    });
}

void MavenJavaFeatureModel::loadCodeVision(std::string targetPath,
                                           std::vector<std::string> paths,
                                           StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingCodeVision = true;
        state_.error.reset();
    }
    coordinator_.javaCodeVision(std::move(targetPath), std::move(paths),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyCodeVision(std::move(result), std::move(handler));
    });
}

void MavenJavaFeatureModel::resolveClassName(std::string source,
                                             std::string simpleName,
                                             StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingClassName = true;
        state_.error.reset();
    }
    coordinator_.javaClassName(std::move(source), std::move(simpleName),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyClassName(std::move(result), std::move(handler));
    });
}

void MavenJavaFeatureModel::findSourceDefinition(std::string source,
                                                 std::string declarationName,
                                                 std::optional<std::string> memberName,
                                                 StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingSourceDefinition = true;
        state_.error.reset();
    }
    coordinator_.javaSourceDefinition(
        std::move(source), std::move(declarationName), std::move(memberName),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applySourceDefinition(std::move(result), std::move(handler));
    });
}

void MavenJavaFeatureModel::findServerPort(std::string content,
                                           std::string fileExtension,
                                           StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingServerPort = true;
        state_.error.reset();
    }
    coordinator_.javaServerPort(std::move(content), std::move(fileExtension),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyServerPort(std::move(result), std::move(handler));
    });
}

void MavenJavaFeatureModel::loadJavaStructure(std::string source,
                                              std::vector<std::string> declarationSources,
                                              StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingStructure = true;
        state_.error.reset();
    }
    coordinator_.javaStructure(std::move(source), std::move(declarationSources),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyStructure(std::move(result), std::move(handler));
    });
}

MavenJavaFeatureState MavenJavaFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void MavenJavaFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
}

void MavenJavaFeatureModel::applyMaven(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingMaven = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeMavenScan(*result.envelope)) {
                state_.maven = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Maven scan response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Maven scan failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void MavenJavaFeatureModel::applyDiagnostics(WorkspaceOperationResult result,
                                             StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingDiagnostics = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeMavenDiagnostics(*result.envelope)) {
                state_.diagnostics = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Maven diagnostics response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Maven diagnostics failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void MavenJavaFeatureModel::applyRunConfigurations(WorkspaceOperationResult result,
                                                   StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingRunConfigurations = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeJavaRunConfigurations(*result.envelope)) {
                state_.runConfigurations = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Java run configurations response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Java run configurations failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void MavenJavaFeatureModel::applyCodeVision(WorkspaceOperationResult result,
                                            StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingCodeVision = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeJavaCodeVision(*result.envelope)) {
                state_.codeVision = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Java code vision response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Java code vision failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void MavenJavaFeatureModel::applyClassName(WorkspaceOperationResult result,
                                           StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingClassName = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeJavaClassName(*result.envelope)) {
                state_.className = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Java class name response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Java class name failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void MavenJavaFeatureModel::applySourceDefinition(WorkspaceOperationResult result,
                                                  StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingSourceDefinition = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeJavaSourceDefinition(*result.envelope)) {
                state_.sourceDefinition = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Java source definition response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Java source definition failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void MavenJavaFeatureModel::applyServerPort(WorkspaceOperationResult result,
                                            StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingServerPort = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeJavaServerPort(*result.envelope)) {
                state_.serverPort = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Java server port response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Java server port failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void MavenJavaFeatureModel::applyStructure(WorkspaceOperationResult result,
                                           StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingStructure = false;
        if (result.envelope && result.envelope->ok) {
            if (auto value = decodeJavaStructure(*result.envelope)) {
                state_.structure = std::move(*value);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Java structure response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Java structure failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

} // namespace lithe::windows::app
