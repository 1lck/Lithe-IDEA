import Combine
import Foundation
import LitheGitModule

@MainActor
extension AppModel {
    var gitFeatureIfActive: GitFeatureModel? {
        gitCapability?.feature
    }

    func activateGitModule() async -> GitFeatureModel? {
        if let feature = gitFeatureIfActive { return feature }
        do {
            let value = try await services.moduleRuntime.activateCapability(.gitWorkspace)
            guard let capability = value as? LitheGitModule.GitModuleCapability else { return nil }
            let feature = capability.feature
            feature.configure(
                workspaceURLProvider: { [weak self] in self?.workspaceURL },
                isGitLogVisibleProvider: { [weak self] in self?.isGitLogVisible ?? false },
                notify: { [weak self] message in self?.showNotification(message) },
                onStateRefreshed: { [weak self] in
                    guard let self, let document = self.activeDocument else { return }
                    await self.refreshCodeVision(for: document.url)
                    await self.loadGitLineChanges(for: document.url)
                },
                saveChangesPolicy: { [weak self] in self?.settings.gitSaveChangesPolicy ?? .stash },
                onGitOperationBegan: { [weak self] in
                    self?.workspaceFeature.beginGitOperationFreeze()
                },
                onGitOperationEnded: { [weak self] in
                    await self?.workspaceFeature.endGitOperationFreeze()
                }
            )
            cacheModuleCapability(capability, id: .gitWorkspace, moduleID: .git)
            observeModuleFeature(.git, observation: feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return feature
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }
}
