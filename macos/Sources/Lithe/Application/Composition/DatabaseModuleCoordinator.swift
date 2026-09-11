import Combine
import LitheApplicationKernel
import LitheDatabaseModule
import LitheModuleAPI

/// Owns activation and suspension of the optional database module.
@MainActor
final class DatabaseModuleCoordinator {
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

    func activate() async -> DatabaseFeatureModel? {
        do {
            let value = try await runtime.activateCapability(.databaseWorkspace)
            guard let capability = value as? DatabaseModuleCapability else {
                throw ModuleRuntimeError.missingCapabilityDependency(
                    module: .database, capability: .databaseWorkspace
                )
            }
            store.cache(capability, id: .databaseWorkspace, moduleID: .database)
            store.observe(.database, observation: capability.feature.objectWillChange.sink { [weak self] _ in
                self?.onChange()
            })
            return capability.feature
        } catch {
            onError(error.localizedDescription)
            return nil
        }
    }

    func sleep() async {
        do {
            try await runtime.sleep(.database)
            store.clear(for: .database)
        } catch {
            onError(error.localizedDescription)
        }
    }
}
