import Foundation
import LitheExecutionModule
import LitheModuleAPI

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

@MainActor
extension AppModel {
    var buildSystemsFeatureIfActive: BuildSystemsFeatureModel? { executionCapability?.buildSystemsFeature }

    /// True when an enabled plugin declares build systems. The Build tool
    /// window is offered only then.
    var hasBuildSystemPlugins: Bool {
        services.pluginCatalog.manifests.contains { manifest in
            let id = ModuleID.buildSystemsExtension(manifest.id.rawValue)
            guard services.pluginCatalog.modules[id] != nil,
                  let snapshot = try? services.moduleRuntime.snapshot(for: id) else { return false }
            return snapshot.state != .disabled && !snapshot.isQuarantined && !snapshot.isSuppressedBySafeMode
        }
    }

    func toggleBuildSystems() {
        guard toggleToolWindow(.buildSystems) else { return }
        Task { [weak self] in
            guard let self, let access = await activateExecutionModule() else { return }
            loadBuildSystems(access)
        }
    }

    /// Detects the current workspace's build systems once per workspace;
    /// later changes arrive through `handleBuildSystemFileChanges`.
    func loadBuildSystems(_ access: ExecutionFeatureAccess) {
        guard let feature = access.buildSystems,
              let workspaceURL = workspaceURL?.standardizedFileURL,
              feature.workspaceURL != workspaceURL else { return }
        feature.reset(workspaceURL: workspaceURL)
    }

    func handleBuildSystemFileChanges(_ changes: [WorkspaceFileChange]) {
        buildSystemsFeatureIfActive?.workspaceFilesChanged(changes.map(\.fileURL))
    }
}
