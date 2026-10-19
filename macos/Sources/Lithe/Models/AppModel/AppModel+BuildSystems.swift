import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

@MainActor
extension AppModel {
    var buildSystemsFeatureIfActive: BuildSystemsFeatureModel? { executionCapability?.buildSystemsFeature }

    /// Detects the current workspace's build systems once per workspace;
    /// later changes arrive through `handleBuildSystemFileChanges`.
    func loadBuildSystems(_ access: ExecutionFeatureAccess) {
        guard let feature = access.buildSystems,
              let identity = currentWorkspaceIdentity else { return }
        feature.onLanguageImportChanged = { [weak self, weak feature] root in
            guard let self, let feature, self.isCurrentWorkspace(identity),
                  root == identity.url, self.buildSystemsFeatureIfActive === feature else { return }
            self.synchronizeBuildLanguageImport(at: root)
        }
        if feature.workspaceURL != identity.url { feature.reset(workspaceURL: identity.url) }
    }

    /// Every Java workflow waits here before it can reach the synchronous
    /// language-session API. Workspace identity includes reopen generations.
    func prepareBuildLanguageImport() async throws {
        guard let identity = currentWorkspaceIdentity else { throw CancellationError() }
        guard hasAvailableBuildSystemPlugins else { return }
        guard let access = await activateExecutionModule(), isCurrentWorkspace(identity) else {
            throw CancellationError()
        }
        loadBuildSystems(access)
        if let feature = access.buildSystems {
            _ = try await feature.prepareLanguageImport(workspaceURL: identity.url)
        }
        try Task.checkCancellation()
        guard isCurrentWorkspace(identity) else { throw CancellationError() }
    }

    var hasAvailableBuildSystemPlugins: Bool {
        services.pluginCatalog.manifests.contains { manifest in
            let id = LitheModuleAPI.ModuleID.buildSystemsExtension(manifest.id.rawValue)
            guard services.pluginCatalog.modules[id] != nil,
                  let snapshot = try? services.moduleRuntime.snapshot(for: id) else { return false }
            return snapshot.state != .disabled && !snapshot.isQuarantined && !snapshot.isSuppressedBySafeMode
        }
    }

    var isBuildLanguageImportPending: Bool {
        hasAvailableBuildSystemPlugins && (
            buildSystemsFeatureIfActive?.workspaceURL != workspaceURL?.standardizedFileURL
                || buildSystemsFeatureIfActive?.languageImport == nil
        )
    }

    func javaLanguageImportConfiguration(rootURL: URL) throws -> JavaLanguageImportConfiguration {
        guard workspaceURL?.standardizedFileURL == rootURL.standardizedFileURL else { throw CancellationError() }
        let pluginImport: JavaLanguageImportConfiguration
        if hasAvailableBuildSystemPlugins {
            guard let feature = buildSystemsFeatureIfActive,
                  feature.workspaceURL == rootURL.standardizedFileURL,
                  let configuration = feature.languageImport else {
                throw RunConfigurationOperationFailure(message: String(localized: "Build-system language import is still preparing. Retry when project loading completes."))
            }
            pluginImport = configuration
        } else {
            pluginImport = JavaLanguageImportConfiguration()
        }
        // Legacy Maven remains the compatibility source only when no plugin
        // supplied that import kind; Run/Debug/Agent keep their existing owner.
        return JavaLanguageImportConfiguration(
            mavenContext: pluginImport.mavenContext ?? mavenFeatureIfActive?.launchContext,
            javaGradle: pluginImport.javaGradle
        )
    }

    private func synchronizeBuildLanguageImport(at rootURL: URL) {
        guard let identity = currentWorkspaceIdentity, identity.url == rootURL.standardizedFileURL,
              !languageToolingFeature.isDisabled("java"),
              let sessions = languageToolingSessionsIfActive else { return }
        javaLanguageServerPreparationCoordinator.synchronizeMavenConfiguration(
            sessions: sessions,
            workspaceURL: identity.url,
            languageImportPreparation: { [weak self] in
                guard let self, self.isCurrentWorkspace(identity) else { throw CancellationError() }
                try await self.prepareBuildLanguageImport()
                guard self.isCurrentWorkspace(identity) else { throw CancellationError() }
            },
            ownsWorkspace: { [weak self, weak sessions] in
                guard let self else { return false }
                return self.isCurrentWorkspace(identity)
                    && !self.languageToolingFeature.isDisabled("java")
                    && self.languageToolingSessionsIfActive === sessions
            }
        )
    }

    func handleBuildSystemFileChanges(_ changes: [WorkspaceFileChange]) {
        buildSystemsFeatureIfActive?.workspaceFilesChanged(changes.map(\.fileURL))
    }
}
