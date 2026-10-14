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
        if let capability: DatabaseModuleCapability = store.capability(.databaseWorkspace) {
            return capability.feature
        }
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
            // Route operation failures through the existing notification owner,
            // even when the database sidebar is hidden. Store clears on sleep.
            store.observe(.database, observation: capability.feature.$errorMessage.dropFirst().compactMap { $0 }.sink { [weak self] message in
                self?.onError(message)
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
