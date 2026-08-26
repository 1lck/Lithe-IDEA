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

    @Test
    func javaWorkspaceResetUsesTheFingerprintFromTheActiveSession() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let runtime = WorkspaceStateLanguageProviderRuntime(
            descriptor: descriptor,
            session: session
        )
        var resetRoot: URL?
        var resetFingerprint: String?
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [runtime],
            workspaceFingerprintProvider: { _, _ in "active-fingerprint" },
            workspaceStateResetter: { _, rootURL, fingerprint in
                resetRoot = rootURL
                resetFingerprint = fingerprint
            }
        )

        try manager.synchronizeLanguageServer(
            for: source,
            text: "class Main {}",
            rootURL: root
        )
        try manager.rebuildWorkspaceState(providerID: "java", rootURL: root)

        #expect(session.startedFingerprint == "active-fingerprint")
        #expect(session.stopCallCount == 1)
        #expect(resetRoot == root.standardizedFileURL)
        #expect(resetFingerprint == "active-fingerprint")
    }

    @Test
    func languageServerLifecycleLogsAndCallbacksRetainTheOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let operationID = UUID()
        var callbacks: [(LanguageServerSessionState, UUID?)] = []
        manager.onLanguageServerStateChange = { providerID, state, callbackOperationID in
            guard providerID == "java" else { return }
            callbacks.append((state, callbackOperationID))
        }

        try manager.startLanguageServer(
            providerID: "java",
            rootURL: root,
            operationID: operationID
        )
        session.publish(.ready)
        manager.stopLanguageServer(providerID: "java")

        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString && $0.message == "Language server ready"
        })
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString && $0.message == "Stopping language server"
        })
        #expect(callbacks.contains { $0.0 == .ready && $0.1 == operationID })
        #expect(callbacks.contains { $0.0 == .stopped && $0.1 == operationID })
        #expect(manager.languageServerOperationIDs["java"] == nil)
    }

    @Test
    func languageServerStartTimeoutIsLoggedWithTheOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let timeoutFailure = LanguageServerSessionFailure(
            code: "timed_out",
            stage: "initialize",
            message: WorkspaceStateSessionError.timedOut.localizedDescription
        )
        session.startError = LanguageServerSessionStartError(failure: timeoutFailure)
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let operationID = UUID()

        #expect(throws: LanguageServerSessionStartError.self) {
            try manager.startLanguageServer(
                providerID: "java",
                rootURL: root,
                operationID: operationID
            )
        }

        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.message == "Language server start timed out"
        })
        #expect(manager.languageServerStates["java"] == .failed(timeoutFailure))
    }

    @Test
    func workspaceCacheCleanupLogsTheLanguageServerOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        var cleanedFingerprint: String?
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )],
            workspaceFingerprintProvider: { _, _ in "active-fingerprint" },
            workspaceStateCleaner: { _, cleanedRoot, fingerprint in
                #expect(cleanedRoot == root.standardizedFileURL)
                cleanedFingerprint = fingerprint
                return 2
            }
        )
        let operationID = UUID()

        try manager.startLanguageServer(
            providerID: "java",
            rootURL: root,
            operationID: operationID
        )

        #expect(cleanedFingerprint == "active-fingerprint")
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.message == "Language server cache cleanup started"
        })
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.message == "Language server cache cleanup succeeded"
                && $0.detail == "removedCount=2"
        })
    }

    @Test
    func workspaceFingerprintFailureIsLoggedAndBlocksStartup() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )],
            workspaceFingerprintProvider: { _, _ in
                throw WorkspaceStateSessionError.unexpectedOperation
            }
        )
        let operationID = UUID()

        #expect(throws: WorkspaceStateSessionError.self) {
            try manager.startLanguageServer(
                providerID: "java",
                rootURL: root,
                operationID: operationID
            )
        }

        #expect(!session.isRunning)
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.level == .error
                && $0.message == "Language server workspace fingerprint failed"
        })
        #expect(manager.languageServerStates["java"] == .failed(LanguageServerSessionFailure(
            code: "workspace_fingerprint_failed",
            stage: "workspaceFingerprint",
            message: WorkspaceStateSessionError.unexpectedOperation.localizedDescription
        )))
    }

    @Test
    func workspaceCacheCleanupFailureIsLoggedAndDoesNotBlockStartup() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )],
            workspaceFingerprintProvider: { _, _ in "active-fingerprint" },
            workspaceStateCleaner: { _, _, _ in
                throw WorkspaceStateSessionError.unexpectedOperation
            }
        )
        let operationID = UUID()

        try manager.startLanguageServer(
            providerID: "java",
            rootURL: root,
            operationID: operationID
        )

        #expect(session.isRunning)
        #expect(session.startedFingerprint == "active-fingerprint")
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.level == .warning
                && $0.message == "Language server cache cleanup failed"
        })
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
private final class WorkspaceStateLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let session: WorkspaceStateLanguageServerSession
    var supportsLanguageServerSession: Bool { true }

    init(
        descriptor: LanguageProviderDescriptor,
        session: WorkspaceStateLanguageServerSession
    ) {
        self.descriptor = descriptor
        self.session = session
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

@MainActor
private final class WorkspaceStateLanguageServerSession: LanguageServerSession {
    var isRunning = false
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    var features: LanguageServerFeatureSet = []
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    var serverInfo: LanguageServerInfo?
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)?
    private(set) var startedFingerprint: String?
    private(set) var stopCallCount = 0
    var startError: Error?

    func start(rootURL _: URL, workspaceFingerprint: String?) throws {
        if let startError { throw startError }
        startedFingerprint = workspaceFingerprint
        isRunning = true
    }

    func publish(_ state: LanguageServerSessionState) {
        onStateChange?(state)
    }

    func synchronize(fileURL _: URL, text _: String, languageID _: String) throws {}
    func closeDocument(_: URL) {}

    func completions(
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion _: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func hover(
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion _: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func navigate(
        method _: String,
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion _: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func rename(
        fileURL _: URL,
        position _: LanguageServerPosition,
        newName _: String,
        completion _: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func format(
        fileURL _: URL,
        completion _: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func codeActions(
        fileURL _: URL,
        range _: LanguageServerRange,
        diagnostics _: [LanguageServerDiagnostic],
        completion _: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func resolveCompletion(
        _: LanguageServerCompletionItem,
        fileURL _: URL,
        completion _: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func resolveCodeAction(
        _: LanguageServerCodeAction,
        fileURL _: URL,
        completion _: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func execute(
        _: LanguageServerCommand,
        fileURL _: URL,
        completion _: @escaping (Result<Void, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func resolveVirtualDocument(
        uri _: String,
        completion _: @escaping (Result<String, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }
}

private enum WorkspaceStateSessionError: LocalizedError {
    case unexpectedOperation
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unexpectedOperation: "Unexpected language-server operation."
        case .timedOut: "Language server initialization timed out."
        }
    }
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
