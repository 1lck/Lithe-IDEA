import Foundation
import LitheApplicationKernel
import LitheModuleAPI
@testable import Lithe
import Testing

@MainActor
struct ModuleRuntimeActivationTests {
    @Test func disablingWhileDependencyStartsNeverConstructsDependent() async throws {
        let runtime = ModuleRuntime()
        let dependency = SuspendedActivationModule()
        let dependentID = ModuleID("test.dependent")
        let manifest = ModuleManifest(id: dependentID, displayName: "Dependent",
            scope: .workspace, dependencies: [.module(dependency.manifest.id)])
        var constructions = 0
        try runtime.register(ModuleFactory(manifest: dependency.manifest) { dependency })
        try runtime.register(ModuleFactory(manifest: manifest) {
            constructions += 1
            return dependency
        })
        let activation = Task { _ = try await runtime.activate(dependentID) }
        defer { activation.cancel(); dependency.release.open() }
        #expect(await dependency.started.waitUntilOpen())
        try await runtime.setEnabled(false, for: dependentID)
        await #expect(throws: CancellationError.self) { try await activation.value }
        #expect(constructions == 0)
        #expect(try runtime.snapshot(for: dependentID).state == .disabled)
        #expect(runtime.capability(SuspendedActivationModule.capabilityID) == nil)
        await runtime.shutdownAll()
    }

    @Test func failedCleanupBlocksRestartUntilDisableRetryStopsResource() async throws {
        let runtime = ModuleRuntime()
        let module = SuspendedActivationModule()
        module.allowResourceStop = false
        try runtime.register(ModuleFactory(manifest: module.manifest) { module })
        let activation = Task { _ = try await runtime.activate(module.manifest.id) }
        defer { activation.cancel(); module.release.open(); module.allowResourceStop = true }
        #expect(await module.started.waitUntilOpen())
        let expected = ModuleRuntimeError.activeResourcesRemain(
            module: module.manifest.id, kinds: [module.moduleResourceKind])
        await #expect(throws: expected) {
            try await runtime.setEnabled(false, for: module.manifest.id)
        }
        await #expect(throws: expected) { try await activation.value }
        await #expect(throws: expected) {
            try await runtime.setEnabled(true, for: module.manifest.id)
        }
        await #expect(throws: ModuleRuntimeError.moduleDisabled(module.manifest.id)) {
            _ = try await runtime.activate(module.manifest.id)
        }
        #expect(module.activationCount == 1)
        module.allowResourceStop = true
        try await runtime.setEnabled(false, for: module.manifest.id)
        #expect(try runtime.snapshot(for: module.manifest.id).state == .disabled)
        #expect(try runtime.snapshot(for: module.manifest.id).activity.activeResourceCount == 0)
    }

    @Test func disablingSuspendedActivationCannotPublishLateCapabilities() async throws {
        let runtime = ModuleRuntime()
        let module = SuspendedActivationModule()
        try runtime.register(ModuleFactory(manifest: module.manifest) { module })
        let activation = Task { _ = try await runtime.activate(module.manifest.id) }
        defer { activation.cancel(); module.release.open() }
        #expect(await module.started.waitUntilOpen())
        let disabling = Task { try await runtime.setEnabled(false, for: module.manifest.id) }
        defer { disabling.cancel() }
        #expect(await module.resourceStopped.waitUntilOpen())
        module.release.open()
        try await disabling.value
        await #expect(throws: CancellationError.self) { _ = try await activation.value }
        #expect(try runtime.snapshot(for: module.manifest.id).state == .disabled)
        #expect(runtime.capability(SuspendedActivationModule.capabilityID) == nil)
        #expect(try !runtime.snapshot(for: module.manifest.id).isInstantiated)
    }

    @Test func concurrentActivationSharesOneInstanceAndOnePreparation() async throws {
        let runtime = ModuleRuntime()
        let module = SuspendedActivationModule()
        var constructions = 0
        try runtime.register(ModuleFactory(manifest: module.manifest) {
            constructions += 1
            return module
        })
        var firstInstance: (any LitheModule)?
        var secondInstance: (any LitheModule)?
        let first = Task { firstInstance = try await runtime.activate(module.manifest.id) }
        let entered = TestGate()
        defer { first.cancel(); entered.open(); module.release.open() }
        #expect(await module.started.waitUntilOpen())
        let second = Task {
            entered.open()
            secondInstance = try await runtime.activate(module.manifest.id)
        }
        defer { second.cancel() }
        #expect(await entered.waitUntilOpen())
        module.release.open()
        try await first.value
        try await second.value
        #expect(firstInstance === secondInstance)
        #expect(constructions == 1)
        #expect(module.activationCount == 1)
        try await runtime.shutdown(module.manifest.id)
        #expect(runtime.capability(SuspendedActivationModule.capabilityID) == nil)
    }
}

@MainActor
private final class SuspendedActivationModule: LitheModule, ModuleResource {
    static let capabilityID = ModuleCapabilityID("test.suspended.capability")
    let manifest = ModuleManifest(id: ModuleID("test.suspended"), displayName: "Suspended",
        scope: .workspace, providedCapabilities: [capabilityID])
    let started = TestGate()
    let release = TestGate()
    let resourceStopped = TestGate()
    let value = NSObject()
    var activationCount = 0
    var allowResourceStop = true
    var isModuleResourceActive = false
    var moduleResourceKind: String { "test.pending-activation" }

    func activate(context: ModuleContext) async throws {
        activationCount += 1
        isModuleResourceActive = true
        context.resources.register(self)
        started.open()
        // Deliberately return success even after cancellation: the runtime must
        // reject this stale result independently of a module's cooperation.
        _ = await release.waitUntilOpen()
    }
    func stopModuleResource() async {
        if allowResourceStop { isModuleResourceActive = false }
        resourceStopped.open()
    }
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [Self.capabilityID: value] }
}
