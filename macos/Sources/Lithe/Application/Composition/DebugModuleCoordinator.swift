import Combine
import Foundation
import LitheApplicationKernel
import LitheDebugModule
import LitheModuleAPI

/// Owns debug capability activation and lifecycle observation.
@MainActor
final class DebugModuleCoordinator {
    private let runtime: ModuleRuntime
    private let store: ModuleCapabilityStore
    private let awaitShutdown: () async -> Void
    private let configure: (GenericDebugFeatureModel) -> Void
    private let openWorkspace: (GenericDebugFeatureModel, URL) -> Void
    private let onStateChange: (DebugAdapterState) -> Void
    private let onChange: () -> Void
    private let onError: (String) -> Void

    init(
        runtime: ModuleRuntime,
        store: ModuleCapabilityStore,
        awaitShutdown: @escaping () async -> Void,
        configure: @escaping (GenericDebugFeatureModel) -> Void,
        openWorkspace: @escaping (GenericDebugFeatureModel, URL) -> Void,
        onStateChange: @escaping (DebugAdapterState) -> Void,
        onChange: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.runtime = runtime
        self.store = store
        self.awaitShutdown = awaitShutdown
        self.configure = configure
        self.openWorkspace = openWorkspace
        self.onStateChange = onStateChange
        self.onChange = onChange
        self.onError = onError
    }

    func activate(workspace: URL?) async -> GenericDebugFeatureModel? {
        await awaitShutdown()
        if let capability: DebugModuleCapability = store.capability(.debugWorkspace),
           let feature = capability.genericFeature as? GenericDebugFeatureModel {
            configure(feature)
            if let workspace { openWorkspace(feature, workspace) }
            return feature
        }
        do {
            let value = try await runtime.activateCapability(ModuleCapabilityID.debugWorkspace)
            guard let capability = value as? DebugModuleCapability,
                  let feature = capability.genericFeature as? GenericDebugFeatureModel else { return nil }
            configure(feature)
            if let workspace { openWorkspace(feature, workspace) }
            store.cache(capability, id: .debugWorkspace, moduleID: .debug)
            store.observe(.debug, observation: feature.objectWillChange.sink { [weak self] (_: ()) in
                self?.onChange()
            })
            store.observe(.debug, observation: feature.$state.removeDuplicates().sink { [weak self] state in
                self?.onStateChange(state)
            })
            return feature
        } catch {
            onError(error.localizedDescription)
            return nil
        }
    }

    func activateAccess(workspace: URL?) async -> DebugFeatureAccess? {
        guard let feature = await activate(workspace: workspace) else { return nil }
        return DebugFeatureAccess(genericFeature: feature)
    }

    func resetFeature(_ feature: GenericDebugFeatureModel?) {
        feature?.reset()
    }

    func stopFeature(_ feature: GenericDebugFeatureModel?) {
        feature?.stop()
    }
}
