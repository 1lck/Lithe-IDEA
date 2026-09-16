import Foundation
import LitheApplicationKernel
import LitheDebugModule
import LitheModuleAPI
import Testing
@testable import Lithe

@MainActor
struct DebugModuleCoordinatorTests {
    @Test
    func activationPublishesAfterTheHostCanResolveTheDebugFeature() async throws {
        let runtime = ModuleRuntime()
        let store = ModuleCapabilityStore()
        for id in [ModuleID.workspace, .languageIntelligence, .execution] {
            let manifest = ModuleManifest(id: id, displayName: id.rawValue, scope: .workspace)
            try runtime.register(ModuleFactory(manifest: manifest) { EmptyDebugDependency(manifest: manifest) })
        }
        let graph = DebugPresentationTestGraph()
        try runtime.register(ModuleFactory(manifest: DebugModule.moduleManifest) {
            DebugModule(makeGraph: { graph })
        })
        var published = 0
        let coordinator = DebugModuleCoordinator(
            runtime: runtime, store: store, awaitShutdown: {}, configure: { _ in },
            openWorkspace: { _, _ in }, onStateChange: { _ in },
            onChange: {
                let capability: DebugModuleCapability? = store.capability(.debugWorkspace)
                #expect(capability?.genericFeature === graph.genericFeatureTarget)
                published += 1
            }, onError: { message in Issue.record("Debug activation failed: \(message)") }
        )
        // These factories do no I/O and start no adapters. The assertion covers
        // the cache/notification ordering even when the feature never changes.
        let first = await coordinator.activate(workspace: nil)
        #expect(first === graph.feature)
        #expect(published == 1)
        let reused = await coordinator.activate(workspace: nil)
        #expect(reused === first)
        #expect(published == 1)
        await runtime.shutdownAll()
        store.clear(for: .debug)
    }
}

@MainActor
private final class DebugPresentationTestGraph: DebugServiceGraph {
    let feature = GenericDebugFeatureModel(sessions: DebugAdapterSessionManager(providers: []) { _, _ in nil })
    var genericFeatureTarget: any GenericDebugFeatureTarget { feature }
    var hasActiveDebugWork: Bool { false }
    func activate(context: ModuleContext) {}
    func prepareForSleep() async throws {}
    func stop() async { feature.reset() }
}

@MainActor
private final class EmptyDebugDependency: LitheModule {
    let manifest: ModuleManifest
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
