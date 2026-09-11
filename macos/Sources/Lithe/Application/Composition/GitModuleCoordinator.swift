import Combine
import Foundation
import LitheApplicationKernel
import LitheGitModule
import LitheModuleAPI

/// Owns activation, caching, and observation of the Git module capability.
@MainActor
final class GitModuleCoordinator {
    struct Handlers {
        let workspaceURL: @MainActor @Sendable () -> URL?
        let gitLogVisible: @MainActor @Sendable () -> Bool
        let notify: @MainActor @Sendable (String) -> Void
        let stateRefreshed: @MainActor @Sendable () async -> Void
        let saveChangesPolicy: @MainActor @Sendable () -> GitSaveChangesPolicy
        let operationBegan: @MainActor @Sendable () -> Void
        let operationEnded: @MainActor @Sendable () async -> Void
        var commitUndone: (@MainActor (String) -> Void)? = nil
    }

    private let runtime: ModuleRuntime
    private let store: ModuleCapabilityStore
    private let onChange: () -> Void
    private let onError: (String) -> Void

    init(
        runtime: ModuleRuntime,
        store: ModuleCapabilityStore,
        onChange: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.runtime = runtime
        self.store = store
        self.onChange = onChange
        self.onError = onError
    }

    func activate() async -> GitFeatureModel? {
        if let capability: GitModuleCapability = store.capability(.gitWorkspace) {
            return capability.feature
        }
        do {
            let value = try await runtime.activateCapability(ModuleCapabilityID.gitWorkspace)
            guard let capability = value as? GitModuleCapability else {
                throw ModuleRuntimeError.missingCapabilityDependency(
                    module: .git, capability: .gitWorkspace
                )
            }
            store.cache(capability, id: .gitWorkspace, moduleID: .git)
            store.observe(.git, observation: capability.feature.objectWillChange.sink { [weak self] (_: ()) in
                self?.onChange()
            })
            return capability.feature
        } catch {
            onError(error.localizedDescription)
            return nil
        }
    }

    func configureIfNeeded(_ feature: GitFeatureModel, handlers: Handlers) {
        guard feature.gitRepositoryRoot == nil else { return }
        feature.historyEditing.onCommitUndone = handlers.commitUndone
        feature.configure(
            workspaceURLProvider: handlers.workspaceURL,
            isGitLogVisibleProvider: handlers.gitLogVisible,
            notify: handlers.notify,
            onStateRefreshed: handlers.stateRefreshed,
            saveChangesPolicy: handlers.saveChangesPolicy,
            onGitOperationBegan: handlers.operationBegan,
            onGitOperationEnded: handlers.operationEnded
        )
    }

    func resetFeature(_ feature: GitFeatureModel?) {
        feature?.reset()
    }
}
