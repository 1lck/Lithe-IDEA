import Foundation
import LitheCoreContracts

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

@MainActor
extension AppModel {
    /// Plugin VCS providers; nil when no installed plugin declares one.
    var vcsProvidersFeature: VcsProvidersFeatureModel? { services.vcsProviders }

    /// Detects the workspace's plugin VCS roots once per workspace; later
    /// changes arrive through `handleVcsProviderFileChanges`.
    func loadVcsProviders(at workspaceURL: URL) {
        guard let feature = vcsProvidersFeature,
              feature.workspaceURL != workspaceURL.standardizedFileURL else { return }
        feature.reset(workspaceURL: workspaceURL)
    }

    func handleVcsProviderFileChanges(_ changes: [WorkspaceFileChange]) {
        vcsProvidersFeature?.workspaceFilesChanged(changes)
    }
}
