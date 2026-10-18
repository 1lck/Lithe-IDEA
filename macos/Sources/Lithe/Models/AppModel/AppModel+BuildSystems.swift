import Foundation
import LitheExecutionModule

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

@MainActor
extension AppModel {
    var buildSystemsFeatureIfActive: BuildSystemsFeatureModel? { executionCapability?.buildSystemsFeature }

    /// True when the open workspace has an instance of the build system. Its
    /// tool window and toggle command are offered only then; disabling the
    /// plugin removes the instances through `pluginsChanged()`.
    func hasDetectedBuildSystem(pluginID: String, buildSystemID: String) -> Bool {
        workspaceURL != nil && buildSystemsFeatureIfActive?.entries.contains {
            $0.instance.pluginID == pluginID && $0.instance.buildSystemID == buildSystemID
        } == true
    }

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

    /// Keep the existing Java session on the same Core-resolved Maven options
    /// the migrated native tool window passes to build plans.
    private func synchronizeBuildLanguageImport(at rootURL: URL) {
        guard let sessions = languageToolingSessionsIfActive else { return }
        if case .failed(let failure) = sessions.updateJavaMavenConfiguration(rootURL: rootURL, reloadProjects: false) {
            sessions.recordLanguageServerLog(
                providerID: "java", level: .warning,
                message: "Build-system Maven import update failed", detail: failure.userMessage
            )
        }
    }

    func handleBuildSystemFileChanges(_ changes: [WorkspaceFileChange]) {
        buildSystemsFeatureIfActive?.workspaceFilesChanged(changes.map(\.fileURL))
    }
}
