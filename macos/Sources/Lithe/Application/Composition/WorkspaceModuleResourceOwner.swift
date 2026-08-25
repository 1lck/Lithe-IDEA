import Foundation
import LitheModuleAPI
import LitheWorkspaceModule

/// Bridges the required Workspace module's resource scope to the UI-facing
/// workspace projection without making the module target depend on app types.
@MainActor
final class WorkspaceModuleResourceOwner: NSObject, WorkspaceResourceGraph {
    private(set) var feature: WorkspaceFeatureModel?

    func attach(workspaceProjection: WorkspaceFeatureModel) {
        feature = workspaceProjection
    }

    var hasActiveResources: Bool {
        feature?.hasActiveModuleResources ?? false
    }

    func stop() async {
        feature?.prepareForModuleRelease()
        feature = nil
    }
}
