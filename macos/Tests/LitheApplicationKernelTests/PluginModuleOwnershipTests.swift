import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import Testing

@MainActor
struct PluginModuleOwnershipTests {
    @Test
    func disableWaitsForLateActivationCleanupBeforeReleasingOwnership() async throws {
        let runtime = ModuleRuntime()
        let module = PendingPluginModule()
        let ownership = RecordingPluginOwnership(module: module)
        runtime.activationOwnership = ownership
        try runtime.register(ModuleFactory(manifest: module.manifest) { module })
        var activationFailed = false
        let activating = Task { @MainActor in
            do { _ = try await runtime.activate(module.manifest.id) }
            catch { activationFailed = true }
        }
        let stoppingStarted = PluginTestSignal()
        var stopping: Task<Void, Error>?
        do {
            try await module.started.waitUntilOpen(timeout: 2)
            #expect(ownership.owned)
            stopping = Task { @MainActor in
                stoppingStarted.open()
                try await runtime.setEnabled(false, for: module.manifest.id)
            }
            try await stoppingStarted.waitUntilOpen(timeout: 2)
            #expect(ownership.owned)
            module.finishActivation.open()
            await activating.value
            try await stopping?.value
            #expect(activationFailed)
            #expect(!ownership.owned)
            #expect(!ownership.releasedWhileActive)
            #expect(try runtime.snapshot(for: module.manifest.id).state == .disabled)
            #expect(try runtime.snapshot(for: module.manifest.id).activity.activeResourceCount == 0)
        } catch {
            module.finishActivation.open()
            await activating.value
            _ = await stopping?.result
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
    }
}

@MainActor
private final class PluginTestSignal {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Error>?

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }

    func waitUntilOpen(timeout: TimeInterval) async throws {
        if isOpen { return }
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.waiter?.resume(throwing: CancellationError())
                self?.waiter = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

@MainActor
private final class PendingPluginModule: LitheModule, ModuleResource {
    let manifest = ModuleManifest(id: .search, displayName: "Pending plugin", scope: .workspace)
    let started = PluginTestSignal()
    let finishActivation = PluginTestSignal()
    let moduleResourceKind = "late-plugin-resource"
    var isModuleResourceActive = false

    func activate(context: ModuleContext) async throws {
        started.open()
        try await finishActivation.waitUntilOpen(timeout: 2)
        // This resource appears after shutdown was requested. The module lease
        // must survive until activation's cancellation path has stopped it.
        isModuleResourceActive = true
        context.resources.register(self)
    }
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func stopModuleResource() async { isModuleResourceActive = false }
}

@MainActor
private final class RecordingPluginOwnership: ModuleActivationOwnership {
    private let module: PendingPluginModule
    var owned = false
    var releasedWhileActive = false
    init(module: PendingPluginModule) { self.module = module }
    func acquire(_ moduleID: ModuleID) throws { owned = true }
    func release(_ moduleID: ModuleID) throws {
        releasedWhileActive = releasedWhileActive || module.isModuleResourceActive
        owned = false
    }
}
