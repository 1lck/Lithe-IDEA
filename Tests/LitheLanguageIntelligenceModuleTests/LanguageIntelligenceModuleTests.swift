import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

@MainActor
struct LanguageIntelligenceModuleTests {
    @Test
    func disabledModuleDoesNotConstructFactoryOrServiceGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: LanguageIntelligenceModule.moduleManifest, contributions: LanguageIntelligenceModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        }, enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.languageIntelligence)) {
            _ = try await runtime.activateCapability(.languageIntelligence)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.graphCalls == 0)
        #expect(try !runtime.snapshot(for: .languageIntelligence).isInstantiated)
    }

    @Test
    func sleepReleasesGraphAndWakeConstructsANewInstance() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: LanguageIntelligenceModule.moduleManifest, contributions: LanguageIntelligenceModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        })

        var firstCapability: LanguageIntelligenceCapability? = try #require(
            try await runtime.activateCapability(.languageIntelligence)
                as? LanguageIntelligenceCapability
        )
        weak var firstSessions = try #require(firstCapability?.sessions)
        weak var firstGraph = recorder.latestGraph
        firstCapability = nil

        try await runtime.sleep(.languageIntelligence)

        #expect(firstGraph == nil)
        #expect(firstSessions == nil)
        #expect(runtime.capability(.languageIntelligence) == nil)
        #expect(try runtime.snapshot(for: .languageIntelligence).activity.activeResourceCount == 0)

        let secondCapability = try #require(
            try await runtime.activateCapability(.languageIntelligence)
                as? LanguageIntelligenceCapability
        )
        #expect(secondCapability.sessions.activeLanguageServerIDs.isEmpty)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.graphCalls == 2)
    }

    @Test
    func goLanguageServerRequiresExtensionRuntimeAndUsesPluginModuleOwner() throws {
        let factory = TestLanguageProviderRuntimeFactory()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimeFactory: factory,
            extensionRequiredProviderIDs: ["go"]
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let source = root.appendingPathComponent("main.go")

        try manager.synchronizeLanguageServer(for: source, text: "package main", rootURL: root)
        #expect(factory.standardRequests.isEmpty)

        let provider = TestLanguageServerExtensionProvider()
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            languageServerModuleID: .languageServerExtension("go")
        )
        #expect(manager.registerLanguageServerExtension(provider, support: support))
        #expect(factory.extensionRequests.count == 1)
        #expect(factory.extensionRequests.first?.ownerModuleID == .languageServerExtension("go"))
        #expect(factory.extensionRequests.first?.launch.executableNames == ["gopls"])
    }

    @Test
    func unregisteringAnExtensionDropsItsRuntimeBeforeReactivation() {
        let factory = TestLanguageProviderRuntimeFactory()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimeFactory: factory,
            extensionRequiredProviderIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            languageServerModuleID: .languageServerExtension("go")
        )
        let provider = TestLanguageServerExtensionProvider()

        #expect(manager.registerLanguageServerExtension(provider, support: support))
        manager.unregisterLanguageServerExtension(languageID: "go")
        #expect(manager.registerLanguageServerExtension(provider, support: support))

        #expect(factory.extensionRequests.count == 2)
        #expect(factory.standardRequests.isEmpty)
    }

    private func makeModule(recorder: Recorder) -> LanguageIntelligenceModule {
        LanguageIntelligenceModule(makeGraph: {
            recorder.graphCalls += 1
            let graph = TestGraph()
            recorder.latestGraph = graph
            return graph
        })
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(
            manifest: ModuleManifest(
                id: .workspace,
                displayName: "Workspace",
                scope: .workspace
            )
        ) {
            EmptyWorkspaceModule()
        }
    }
}

@MainActor
private final class Recorder {
    var factoryCalls = 0
    var graphCalls = 0
    weak var latestGraph: TestGraph?
}

@MainActor
private final class TestGraph: LanguageIntelligenceServiceGraph {
    let sessions = LanguageToolingSessionManager()
    let tools = LanguageServerToolService(
        runtimeService: TestLanguageToolRuntime(),
        commandRunner: TestLanguageToolCommandRunner(),
        settingsStore: TestLanguageToolSettingsStore()
    )
    var hasActiveLanguageServers = false

    func activate(context: ModuleContext) {}
    func prepareForSleep() async throws {}
    func stop() async {}
}

@MainActor
private final class TestLanguageToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment() -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { "Missing \(name)." }
}

private struct TestLanguageToolCommandRunner: LanguageToolCommandRunning {
    func runLanguageToolCommand(
        operationID _: String,
        executableURL _: URL,
        arguments _: [String],
        environment _: [String: String],
        timeoutMilliseconds _: Int
    ) -> LanguageToolCommandResult {
        LanguageToolCommandResult(output: "", exitCode: 0)
    }
}

private final class TestLanguageToolSettingsStore: LanguageToolSettingsStoring {
    func loadLanguageToolExecutablePaths() -> [String: String] { [:] }
    func saveLanguageToolExecutablePaths(_: [String: String]) {}
}

@MainActor
private final class TestLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
    struct ExtensionRequest {
        let launch: LanguageServerLaunchDescriptor
        let ownerModuleID: ModuleID
    }

    private(set) var standardRequests: [LanguageProviderDescriptor] = []
    private(set) var extensionRequests: [ExtensionRequest] = []

    func makeRuntime(for descriptor: LanguageProviderDescriptor) -> (any LanguageProviderRuntime)? {
        standardRequests.append(descriptor)
        return TestLanguageProviderRuntime(descriptor: descriptor)
    }

    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)? {
        extensionRequests.append(ExtensionRequest(
            launch: languageServerLaunch,
            ownerModuleID: ownerModuleID
        ))
        return TestLanguageProviderRuntime(descriptor: descriptor)
    }
}

@MainActor
private final class TestLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    init(descriptor: LanguageProviderDescriptor) { self.descriptor = descriptor }
}

@MainActor
private final class TestLanguageServerExtensionProvider: LanguageServerExtensionProviding {
    let configuration = LanguageServerExtensionConfiguration(
        languageID: "go",
        displayName: "Go",
        executableNames: ["gopls"],
        languageIdentifier: "go"
    )
    let lifecycle: any LanguageServerExtensionLifecycle = TestLanguageServerExtensionLifecycle()
}

@MainActor
private final class TestLanguageServerExtensionLifecycle: LanguageServerExtensionLifecycle {
    private var running: @MainActor () -> Bool = { false }
    private var stopAction: @MainActor () -> Void = {}
    var isRunning: Bool { running() }
    func attach(
        isRunning: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        running = isRunning
        stopAction = stop
    }
    func stop() { stopAction() }
}

@MainActor
private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(
        id: .workspace,
        displayName: "Workspace",
        scope: .workspace
    )

    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
