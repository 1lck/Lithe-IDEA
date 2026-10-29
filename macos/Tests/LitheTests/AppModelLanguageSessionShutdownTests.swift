import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

@MainActor
struct AppModelLanguageSessionShutdownTests {
    @Test
    func closingSessionRevokesLanguageActivationWaitingForWorkspaceCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("language-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Main.startup")
        try "test".write(to: file, atomically: true, encoding: .utf8)
        let store = ShutdownTestStore()
        let settings = AppSettings(store: store)
        let processes = ManagedProcessRegistry()
        let container = MacServiceContainer(store: store, settings: settings, processRegistry: processes)
        defer { container.moduleLifecycleCoordinator.stop() }
        let base = container.services
        let runtime = base.moduleRuntime
        let started = TestGate(), release = TestGate(), queued = TestGate()
        let blocker = ShutdownGateModule(started: started, release: release)
        try runtime.register(ModuleFactory(manifest: blocker.manifest) { blocker })
        let model = AppModel(settings: settings, services: services(base))
        var closing: Task<Void, Never>?
        var activation: Task<LanguageIntelligenceCapability, Error>?
        try await WorkbenchTestScope.withCleanup({
            release.open()
            activation?.cancel()
            if let closing { await closing.value }
            _ = try? await activation?.value
            await model.shutdownProjectSession()
        }) { scope in
            defer { release.open(); activation?.cancel() }
            try await scope.run("prepare workspace cleanup") {
                _ = try await runtime.activate(blocker.manifest.id)
                model.openProjectDirectly(root)
                try #require(await started.waitUntilOpen())
                await model.documentFeature.openFileAsync(file, isReadOnly: false, displayPath: nil, activateWhenReady: true)
            }
            let document = try #require(model.openDocuments.first { $0.url == file })
            let identity = try #require(model.currentWorkspaceIdentity)
            model.setProjectSessionActive(false)
            #expect(model.isCurrentWorkspace(identity), "A background project is still a live session")
            #expect(!model.activateLanguageServerIfAvailable(for: document))
            activation = Task { @MainActor in
                queued.open()
                return try await model.languageIntelligenceModuleCoordinator.activate()
            }
            try #require(await queued.waitUntilOpen())
            closing = Task { @MainActor in await model.shutdownProjectSession() }
            // Observe the actual close entry, not task scheduling. The model is
            // intentionally retained with its workspace and document, as in Settings.
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.isProjectSessionClosed && clock.now < deadline { await Task.yield() }
            try #require(model.isProjectSessionClosed)
            #expect(!model.isCurrentWorkspace(identity))
            #expect(model.workspaceURL?.path == root.path)
            #expect(model.openDocuments.contains { $0 === document })
            release.open()
            try await scope.run("finish closing and pending language activation") {
                await closing?.value
                let activation = try #require(activation)
                await #expect(throws: CancellationError.self) { try await activation.value }
                #expect(!model.activateLanguageServerIfAvailable(for: document))
                #expect(runtime.capability(.languageIntelligence) == nil)
                #expect(model.languageToolingSessionsIfActive == nil)
                #expect(processes.processIDs(for: ManagedProcessCategory.languageServer).isEmpty)
            }
        }
    }

    private func services(_ base: AppServices) -> AppServices {
        AppServices(moduleRuntime: base.moduleRuntime, pluginManager: base.pluginManager,
            pluginMarketplace: base.pluginMarketplace, pluginCatalog: base.pluginCatalog,
            languageProviderCatalogSource: ShutdownTestCatalog(),
            workspaceLanguageServerPreferences: base.workspaceLanguageServerPreferences,
            javaTestResultServerFactory: { MacJavaTestResultServer() },
            workspaceOperations: base.workspaceOperations, documentLifecycleDecider: base.documentLifecycleDecider,
            lineEditing: base.lineEditing, javaMavenOperations: base.javaMavenOperations,
            markdownRenderer: base.markdownRenderer, markdownImageImporter: base.markdownImageImporter,
            store: base.store, fileStorage: base.fileStorage, fileOperations: base.fileOperations,
            binaryFileViewerRegistry: base.binaryFileViewerRegistry, projectRuntimeService: base.projectRuntimeService,
            gitWatchContextProvider: base.gitWatchContextProvider, githubService: base.githubService,
            secureStore: base.secureStore, diagnosticsExportService: base.diagnosticsExportService,
            credentialResolver: base.credentialResolver, aiConfigurationSources: [],
            recentProjectsStore: base.recentProjectsStore, workspaceSessionStore: base.workspaceSessionStore,
            directoryMarkStore: base.directoryMarkStore, workbenchLayoutStore: base.workbenchLayoutStore,
            workbenchBackgroundPlatform: base.workbenchBackgroundPlatform, directoryWatcherFactory: base.directoryWatcherFactory,
            platformUI: base.platformUI, shortcutDetectorFactory: base.shortcutDetectorFactory)
    }
}

@MainActor
private final class ShutdownGateModule: LitheModule {
    let manifest = ModuleManifest(id: ModuleID("zz.test-language-close"), displayName: "Test close gate", scope: .workspace)
    let started: TestGate, release: TestGate
    init(started: TestGate, release: TestGate) { self.started = started; self.release = release }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {
        started.open()
        #expect(await release.waitUntilOpen(timeout: .seconds(5)), "Workspace shutdown gate was not released")
    }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct ShutdownTestCatalog: LanguageProviderCatalogSource {
    func load(workspaceURL: URL?) -> LanguageProviderCatalogSnapshot {
        .init(catalog: LanguageProviderCatalog(descriptors: [
            LanguageProviderDescriptor(id: "test-startup", displayName: "Test startup", fileExtensions: ["startup"],
                capabilities: [.languageServer], activationPolicy: .onDemand)
        ]), schemaVersion: nil, origin: .builtin, issues: [])
    }
}

private final class ShutdownTestStore: KeyValueStore {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
