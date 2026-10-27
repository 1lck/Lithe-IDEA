import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

@MainActor
struct LanguageIntelligenceModuleCoordinatorTests {
    @Test(arguments: [false, true], [false, true])
    func languageActivationWaitsForWorkspaceTeardown(maintenance: Bool, cancel: Bool) async throws {
        let runtime = ModuleRuntime()
        let store = ModuleCapabilityStore()
        let started = TestGate(), release = TestGate(), joined = TestGate(), finished = TestGate()
        var graphs: [StartupLanguageGraph] = []
        let workspace = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
        try runtime.register(ModuleFactory(manifest: workspace) { StartupWorkspaceModule(manifest: workspace) })
        try runtime.register(ModuleFactory(manifest: LanguageIntelligenceModule.moduleManifest,
            contributions: LanguageIntelligenceModule.moduleContributions) {
            LanguageIntelligenceModule(makeGraph: {
                let graph = StartupLanguageGraph()
                graphs.append(graph)
                return graph
            })
        })
        let session = ModuleSessionCoordinator(
            runtime: runtime, capabilities: store, workbench: WorkbenchFeatureModel(),
            onModuleReleased: { _ in }, onChange: {},
            shutdownRuntime: {
                started.open()
                #expect(await release.waitUntilOpen(timeout: .seconds(5)), "Workspace cleanup was not released")
                await runtime.shutdownAll()
            }
        )
        var teardownPending = false
        let coordinator = LanguageIntelligenceModuleCoordinator(
            runtime: runtime, store: store,
            awaitShutdown: {
                if teardownPending { joined.open() }
                await session.awaitShutdown()
            },
            bind: { store.cache($0, id: .languageIntelligence, moduleID: .languageIntelligence) },
            notify: { Issue.record("\($0)") }
        )
        var request: Task<LanguageToolingSessionManager, Error>?
        try await WorkbenchTestScope.withCleanup({
            release.open()
            request?.cancel()
            _ = try? await request?.value
            await session.awaitShutdown()
            await runtime.shutdownAll()
            session.stopObserving()
        }) { _ in
            let old = try await coordinator.activate().sessions
            teardownPending = true
            session.beginShutdown()
            try #require(await started.waitUntilOpen())
            // Keep old capabilities cached while cleanup is suspended, as on
            // startup. Neither the cache nor the maintenance path may bypass it.
            request = Task { @MainActor in
                defer { finished.open() }
                if maintenance { return try await coordinator.sessionsForMaintenance() }
                return try await coordinator.activate().sessions
            }
            #expect(await joined.waitUntilOpen(), "Language activation bypassed workspace cleanup")
            #expect(!finished.isOpen)
            #expect(graphs.count == 1)
            if cancel { request?.cancel() }
            release.open()
            let request = try #require(request)
            if cancel {
                await #expect(throws: CancellationError.self) { try await request.value }
                #expect(graphs.count == 1)
            } else {
                let current = try await request.value
                #expect(current !== old)
                #expect(graphs.count == 2)
                #expect(graphs[0].stopped)
                #expect(try #require(graphs.last).stopped == false)
                #expect(store.capability(.languageIntelligence, as: LanguageIntelligenceCapability.self)?.sessions === current)
            }
        }
    }
}

@MainActor
private final class StartupWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

@MainActor
private final class StartupLanguageGraph: LanguageIntelligenceServiceGraph, LanguageToolRuntimePort {
    let sessions = LanguageToolingSessionManager()
    lazy var tools = LanguageServerToolService(
        runtimeService: self, commandRunner: StartupLanguageTools(), settingsStore: StartupLanguageTools()
    )
    var stopped = false
    var hasActiveLanguageServers: Bool { false }
    func activate(context: ModuleContext) {}
    func prepareForSleep() async throws {}
    func stop() async { stopped = true; sessions.stopAllLanguageServers() }
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}

private final class StartupLanguageTools: LanguageToolCommandRunning, LanguageToolSettingsStoring, @unchecked Sendable {
    func loadLanguageToolExecutablePaths() -> [String: String] { [:] }
    func saveLanguageToolExecutablePaths(_: [String: String]) {}
    func runLanguageToolCommand(operationID: String, executableURL: URL, arguments: [String],
        environment: [String: String], timeoutMilliseconds: Int) -> LanguageToolCommandResult {
        LanguageToolCommandResult(output: "", exitCode: 0)
    }
}
