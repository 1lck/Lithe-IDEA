import Combine
import Foundation
import LitheGitModule

@MainActor
extension AppModel {
    var gitFeatureIfActive: GitFeatureModel? {
        gitCapability?.feature
    }

    func activateGitModule() async -> GitFeatureModel? {
        guard let feature = await gitModuleCoordinator.activate() else { return nil }
        gitModuleCoordinator.configureIfNeeded(
            feature,
            handlers: .init(
                workspaceURL: { [weak self] in self?.workspaceURL },
                gitLogVisible: { [weak self] in self?.isGitLogVisible ?? false },
                notify: { [weak self] message in self?.showNotification(message) },
                stateRefreshed: { [weak self] in
                    guard let self, let document = self.activeDocument else { return }
                    await self.refreshCodeVision(for: document.url)
                    await self.loadGitLineChanges(for: document.url)
                },
                saveChangesPolicy: { [weak self] in
                    self?.settings.gitSaveChangesPolicy ?? .stash
                },
                operationBegan: { [weak self] in
                    self?.workspaceFeature.beginGitOperationFreeze()
                },
                operationEnded: { [weak self] in
                    await self?.workspaceFeature.endGitOperationFreeze()
                }
            )
        )
        return feature
    }

}
