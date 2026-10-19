import Foundation
import LitheApplicationKernel
import LitheDebugModule
import LitheModuleAPI
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct DebugModuleCoordinatorTests {
    @Test(arguments: [false, true], [false, true])
    func toolbarDebugRestartsOnlyTheSelectedTarget(paused: Bool, sameTarget: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: store, settings: settings).services)
        let runtime = ModuleRuntime()
        for id in [ModuleID.workspace, .languageIntelligence, .execution] {
            let manifest = ModuleManifest(id: id, displayName: id.rawValue, scope: .workspace)
            try runtime.register(ModuleFactory(manifest: manifest) { EmptyDebugDependency(manifest: manifest) })
        }
        let adapter = ToolbarTargetDebugSession(paused: paused)
        let sessions = DebugAdapterSessionManager(providers: [
            DebugProviderDescriptor(id: "java", displayName: "Java", fileExtensions: ["java"])
        ]) { _, _ in adapter }
        let feature = GenericDebugFeatureModel(sessions: sessions)
        let graph = DebugPresentationTestGraph(feature: feature)
        try runtime.register(ModuleFactory(manifest: DebugModule.moduleManifest,
            contributions: DebugModule.moduleContributions) { DebugModule(makeGraph: { graph }) })
        try await WorkbenchTestScope.withCleanup({
            await model.shutdownProjectSession()
            await runtime.shutdownAll()
        }) { _ in
            model.openProjectDirectly(root)
            _ = try await runtime.activate(.debug)
            let capability = try #require(runtime.capability(.debugWorkspace) as? DebugModuleCapability)
            model.cacheModuleCapability(capability, id: .debugWorkspace, moduleID: .debug)
            let source = root.appendingPathComponent("Tests.java")
            #expect(feature.start(fileURL: source, rootURL: root,
                configuration: DebugLaunchConfiguration(name: "check()", request: .launch, arguments: [:])))
            try #require(feature.state == (paused ? .paused : .running))
            let selected = sameTarget ? "demo.First#check()" : "demo.Second#check()"
            var target = ActiveTestTarget(providerID: "java", scope: .testCase(identifier: selected, fileURL: nil))
            if sameTarget { target.resolvedName = "check()" }
            model.activeTestTarget = target
            model.clearNotifications()
            WorkbenchModuleUIComposition.builtIn.performAction(id: "workbench.debug-start-or-restart", model: model)
            #expect(adapter.launchCount == (sameTarget ? 2 : 1))
            if !sameTarget {
                // Reaching the source guard proves B entered test preparation instead of restarting A.
                #expect(model.notifications.contains { $0.message == "The selected Java test has no source file" })
                #expect(model.activeTestTarget?.scope == target.scope)
            }
        }
    }

    @Test
    func activationPublishesAfterTheHostCanResolveTheDebugFeature() async throws {
        let runtime = ModuleRuntime()
        let store = ModuleCapabilityStore()
        for id in [ModuleID.workspace, .languageIntelligence, .execution] {
            let manifest = ModuleManifest(id: id, displayName: id.rawValue, scope: .workspace)
            try runtime.register(ModuleFactory(manifest: manifest) { EmptyDebugDependency(manifest: manifest) })
        }
        let graph = DebugPresentationTestGraph()
        try runtime.register(ModuleFactory(
            manifest: DebugModule.moduleManifest,
            contributions: DebugModule.moduleContributions
        ) {
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
    let feature: GenericDebugFeatureModel
    init(feature: GenericDebugFeatureModel = GenericDebugFeatureModel(sessions: DebugAdapterSessionManager(providers: []) { _, _ in nil })) {
        self.feature = feature
    }
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

@MainActor
private final class ToolbarTargetDebugSession: DebugAdapterControllingSession {
    let paused: Bool
    var isRunning = false
    var state: DebugAdapterState { isRunning ? (paused ? .paused : .running) : .idle }
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?
    private(set) var launchCount = 0
    init(paused: Bool) { self.paused = paused }
    func start(rootURL: URL) throws { isRunning = true }
    func stop() { isRunning = false }
    func launch(_ configuration: DebugLaunchConfiguration) throws { launchCount += 1 }
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {}
    func execute(_ command: DebugExecutionCommand, threadID: Int?) {}
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) { completion(.success([])) }
    func requestStackTrace(threadID: Int, completion: @escaping (Result<[DebugStackFrame], Error>) -> Void) { completion(.success([])) }
    func requestScopes(frameID: Int, completion: @escaping (Result<[DebugScope], Error>) -> Void) { completion(.success([])) }
    func requestVariables(reference: Int, completion: @escaping (Result<[DebugVariable], Error>) -> Void) { completion(.success([])) }
    func evaluate(_ expression: String, frameID: Int?, completion: @escaping (Result<DebugVariable, Error>) -> Void) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("evaluation")))
    }
}
