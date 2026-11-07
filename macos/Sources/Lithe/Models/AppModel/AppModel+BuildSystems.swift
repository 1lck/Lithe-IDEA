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
        if feature.workspaceURL != identity.url { feature.reset(workspaceURL: identity.url) }
    }

    /// Run, test and debug workflows wait here so they never start with
    /// option values from before a save. Workspace identity includes reopen generations.
    func awaitBuildSystemDetection() async throws {
        guard let identity = currentWorkspaceIdentity else { throw CancellationError() }
        guard hasAvailableBuildSystemPlugins else { return }
        guard let access = await activateExecutionModule(), isCurrentWorkspace(identity) else {
            throw CancellationError()
        }
        loadBuildSystems(access)
        if let feature = access.buildSystems {
            try await feature.awaitDetection(workspaceURL: identity.url)
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

    func handleBuildSystemFileChanges(_ changes: [WorkspaceFileChange]) {
        buildSystemsFeatureIfActive?.workspaceFilesChanged(changes.map(\.fileURL))
    }
}
