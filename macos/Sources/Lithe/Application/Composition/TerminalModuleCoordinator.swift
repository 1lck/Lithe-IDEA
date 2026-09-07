import Combine
import LitheApplicationKernel
import LitheModuleAPI
import LitheTerminalModule

/// Owns activation and observation of the integrated terminal module.
@MainActor
final class TerminalModuleCoordinator {
    private let runtime: ModuleRuntime
    private let store: ModuleCapabilityStore
    private let onChange: () -> Void

    init(runtime: ModuleRuntime, store: ModuleCapabilityStore, onChange: @escaping () -> Void) {
        self.runtime = runtime
        self.store = store
        self.onChange = onChange
    }

    func activate() async -> Bool {
        if store.capability(.terminalWorkspace) as LitheTerminalModule.TerminalModuleCapability? != nil {
            return true
        }
        do {
            let value = try await runtime.activateCapability(ModuleCapabilityID.terminalWorkspace)
            guard let capability = value as? TerminalModuleCapability else { return false }
            store.cache(capability, id: .terminalWorkspace, moduleID: .terminal)
            store.observe(.terminal, observation: capability.feature.objectWillChange.sink { [weak self] (_: ()) in
                self?.onChange()
            })
            return true
        } catch {
            return false
        }
    }

    func activateThen(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            guard let self, await activate() else { return }
            action()
        }
    }

    func stopAllSessions(_ feature: TerminalFeatureModel?) {
        feature?.stopAllSessions()
    }
}
