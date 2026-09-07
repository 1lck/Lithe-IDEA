import Combine
import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import LitheSearchModule

/// Owns activation and initial warming of the search module capability.
@MainActor
final class SearchModuleCoordinator {
    private let runtime: ModuleRuntime
    private let store: ModuleCapabilityStore
    private let workspace: @MainActor () -> URL?
    private let visibilityRules: @MainActor () -> FileVisibilityRules
    private let onChange: () -> Void
    private let onError: (String) -> Void

    init(
        runtime: ModuleRuntime,
        store: ModuleCapabilityStore,
        workspace: @escaping @MainActor () -> URL?,
        visibilityRules: @escaping @MainActor () -> FileVisibilityRules,
        onChange: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.runtime = runtime
        self.store = store
        self.workspace = workspace
        self.visibilityRules = visibilityRules
        self.onChange = onChange
        self.onError = onError
    }

    func activate() async -> SearchFeatureModel? {
        if let capability: SearchModuleCapability = store.capability(.searchWorkspace) {
            return capability.feature
        }
        do {
            let value = try await runtime.activateCapability(.searchWorkspace)
            guard let capability = value as? SearchModuleCapability else {
                throw ModuleRuntimeError.missingCapabilityDependency(
                    module: .search,
                    capability: .searchWorkspace
                )
            }
            store.cache(capability, id: .searchWorkspace, moduleID: .search)
            store.observe(.search, observation: capability.feature.objectWillChange.sink { [weak self] _ in
                self?.onChange()
            })
            if let workspace = workspace() {
                capability.feature.warmIndex(
                    at: workspace,
                    visibilityRules: visibilityRules().searchRules
                )
            }
            return capability.feature
        } catch {
            onError(error.localizedDescription)
            return nil
        }
    }

    func resetFeature(_ feature: SearchFeatureModel?) {
        feature?.reset()
    }
}
