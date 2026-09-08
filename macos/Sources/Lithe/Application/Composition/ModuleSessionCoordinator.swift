import Foundation
import LitheApplicationKernel
import LitheModuleAPI

/// Owns module events and coalesced graph shutdown for one application session.
@MainActor
final class ModuleSessionCoordinator {
    private let runtime: ModuleRuntime
    private let capabilities: ModuleCapabilityStore
    private let workbench: WorkbenchFeatureModel
    private let onModuleReleased: (ModuleID) -> Void
    private let onChange: () -> Void
    private let shutdownRuntime: () async -> Void
    private var observationID: UUID?
    private var shutdownTask: Task<Void, Never>?

    init(
        runtime: ModuleRuntime,
        capabilities: ModuleCapabilityStore,
        workbench: WorkbenchFeatureModel,
        onModuleReleased: @escaping (ModuleID) -> Void,
        onChange: @escaping () -> Void,
        shutdownRuntime: (() async -> Void)? = nil
    ) {
        self.runtime = runtime
        self.capabilities = capabilities
        self.workbench = workbench
        self.onModuleReleased = onModuleReleased
        self.onChange = onChange
        self.shutdownRuntime = shutdownRuntime ?? { await runtime.shutdownAll() }
        observationID = runtime.observeEvents { [weak self] event in
            self?.handle(event)
        }
    }

    func clearBindings(for moduleID: ModuleID) {
        capabilities.clear(for: moduleID)
        onModuleReleased(moduleID)
    }

    func beginShutdown() {
        guard shutdownTask == nil else { return }
        let shutdownRuntime = self.shutdownRuntime
        // Shutdown must finish even if the shell is released in the meantime.
        shutdownTask = Task { @MainActor [weak self] in
            await shutdownRuntime()
            guard let self else { return }
            self.shutdownTask = nil
            self.clearBindings(for: .database)
        }
    }

    func shutdown() async {
        beginShutdown()
        await awaitShutdown()
    }

    func awaitShutdown() async {
        // A second teardown can begin while an activation is waiting for the
        // first. Join it too before allowing that activation to continue.
        while let shutdownTask {
            await shutdownTask.value
        }
    }

    func stopObserving() {
        guard let observationID else { return }
        runtime.removeEventObserver(observationID)
        self.observationID = nil
    }

    private func handle(_ event: ModuleEvent) {
        if event.name == "module.sleeping" || event.name == "module.shutdown" {
            if event.source == .database, workbench.selectedSidebar == .database {
                workbench.selectedSidebar = .project
            }
            clearBindings(for: event.source)
        }
        if event.name == ModuleEvent.stateChangedName
            || event.name == "module.sleeping"
            || event.name == "module.shutdown" {
            onChange()
        }
    }

    isolated deinit {
        if let observationID { runtime.removeEventObserver(observationID) }
    }
}
