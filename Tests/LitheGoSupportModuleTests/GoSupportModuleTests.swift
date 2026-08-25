import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheGoSupportModule
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

@MainActor
struct GoSupportModuleTests {
    @Test
    func lspAndExecutionActivateAndDisableIndependently() async throws {
        let runtime = ModuleRuntime()
        let executionHost = GoTestExecutionHost()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            GoTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: GoLanguageServerModule.moduleManifest) {
            GoLanguageServerModule()
        })
        try runtime.register(ModuleFactory(manifest: GoExecutionModule.moduleManifest) {
            GoExecutionModule(executionHost: executionHost)
        })
        try runtime.validateGraph()
        try await runtime.setEnabled(true, for: .languageServerExtension("go"))
        try await runtime.setEnabled(true, for: .languageExecutionExtension("go"))

        let lsp = try await runtime.activateCapability(.languageServerExtension("go"))
        let execution = try await runtime.activateCapability(.languageExecutionExtension("go"))
        let testing = try await runtime.activateCapability(.languageTestingExtension("go"))
        #expect(lsp is GoLanguageServerCapability)
        #expect(execution is GoExecutionCapability)
        let testingCapability = try #require(testing as? GoExecutionCapability)
        let executionObject = try #require(execution as? GoExecutionCapability)
        #expect(ObjectIdentifier(testingCapability) == ObjectIdentifier(executionObject))

        let lspCapability = try #require(lsp as? GoLanguageServerCapability)
        let lspLifecycle = GoTestLanguageServerLifecycleState()
        lspCapability.lifecycle.attach(
            isRunning: { lspLifecycle.isRunning },
            stop: {
                lspLifecycle.isRunning = false
                lspLifecycle.stopCalls += 1
            }
        )

        try await runtime.setEnabled(false, for: .languageServerExtension("go"))
        #expect(lspLifecycle.stopCalls == 1)
        #expect(!lspLifecycle.isRunning)
        #expect(try runtime.snapshot(for: .languageServerExtension("go")).state == .disabled)
        #expect(try runtime.snapshot(for: .languageServerExtension("go")).activity.activeResourceCount == 0)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("go")).state == .active)

        let executionCapability = try #require(execution as? GoExecutionCapability)
        let executionSession = executionCapability.makeExecutionSession()
        let testSession = executionCapability.makeTestExecutionSession()
        try executionSession.start(LanguageExecutionProcessRequest(
            executablePath: "/fixture/go",
            arguments: ["run", "main.go"]
        ))
        try testSession.start(LanguageExecutionProcessRequest(
            executablePath: "/fixture/go",
            arguments: ["test", "./..."]
        ))
        #expect(executionSession.isRunning)
        #expect(testSession.isRunning)
        #expect(executionHost.sessions.count == 2)

        try await runtime.setEnabled(false, for: .languageExecutionExtension("go"))
        #expect(!executionSession.isRunning)
        #expect(!testSession.isRunning)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("go")).activity.activeResourceCount == 0)
    }

    @Test
    func executionDisableFailsWhenAnOwnedProcessCannotBeStopped() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            GoTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: GoExecutionModule.moduleManifest) {
            GoExecutionModule(executionHost: GoStuckExecutionHost())
        })
        try await runtime.setEnabled(true, for: .languageExecutionExtension("go"))

        let capability = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("go"))
                as? any LanguageRunExtensionProviding
        )
        let session = capability.makeExecutionSession()
        try session.start(LanguageExecutionProcessRequest(executablePath: "/fixture/go"))

        await #expect(throws: ModuleRuntimeError.activeResourcesRemain(
            module: .languageExecutionExtension("go"),
            kinds: ["language-execution-process"]
        )) {
            try await runtime.setEnabled(false, for: .languageExecutionExtension("go"))
        }
        let snapshot = try runtime.snapshot(for: .languageExecutionExtension("go"))
        #expect(snapshot.activity.activeResourceCount == 1)
        guard case .failed = snapshot.state else {
            Issue.record("The module must report a failed shutdown while its process remains active")
            return
        }
    }

    @Test
    func executionActivityBlocksSleepAndCompletionMakesTheModuleIdle() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            GoTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: GoExecutionModule.moduleManifest) {
            GoExecutionModule(executionHost: GoTestExecutionHost())
        })
        try await runtime.setEnabled(true, for: .languageExecutionExtension("go"))

        let capability = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("go"))
                as? any LanguageRunExtensionProviding
        )
        let session = capability.makeExecutionSession()
        try session.start(LanguageExecutionProcessRequest(
            operationID: "go-run",
            executablePath: "/fixture/go"
        ))
        let moduleID = ModuleID.languageExecutionExtension("go")
        #expect(try runtime.snapshot(for: moduleID).activity.activeLeaseCount == 1)
        await #expect(throws: ModuleRuntimeError.activeLeasesPreventSleep(
            module: moduleID,
            reasons: ["Language execution go-run"]
        )) {
            try await runtime.sleep(moduleID)
        }

        session.stop()
        let idle = try runtime.snapshot(for: moduleID)
        #expect(idle.state == .idle)
        #expect(idle.activity.activeLeaseCount == 0)

        try await runtime.sleep(moduleID)
        #expect(try runtime.snapshot(for: moduleID).state == .sleeping)
    }

    @Test
    func goExecutionProducesAWorkspaceRelativeLaunchPlan() throws {
        let capability = GoExecutionCapability(executionSession: GoTestExecutionSession())
        let plan = try capability.launchPlan(for: LanguageRunExtensionRequest(
            relativeFilePath: "cmd/server/main.go",
            arguments: ["--port", "8080"],
            environment: ["GOFLAGS": "-mod=readonly"]
        ))

        #expect(plan.executable == .toolchain("project-go"))
        #expect(plan.arguments == ["run", "cmd/server/main.go", "--port", "8080"])
        #expect(plan.workingDirectory == ".")
        #expect(plan.environment == ["GOFLAGS": "-mod=readonly"])
    }

    @Test
    func goExecutionRejectsPathsOutsideTheWorkspace() {
        let capability = GoExecutionCapability(executionSession: GoTestExecutionSession())
        #expect(throws: LanguageRunExtensionError.invalidRelativePath) {
            _ = try capability.launchPlan(for: LanguageRunExtensionRequest(
                relativeFilePath: "../outside.go"
            ))
        }
    }

    @Test
    func goTestingDiscoversFilesAndBuildsAnOwnedTestPlan() throws {
        let session = GoTestExecutionSession()
        let capability = GoExecutionCapability(executionSession: session)
        let projectFiles = [
            "go.mod",
            "cmd/api/main.go",
            "cmd/api/main_test.go",
            "internal/store/store_test.go"
        ]

        let items = try capability.discoverTests(for: LanguageTestExtensionDiscoveryRequest(
            relativeProjectFilePaths: projectFiles
        ))
        #expect(items.map(\.id) == [
            "go:workspace",
            "go:file:cmd/api/main_test.go",
            "go:file:internal/store/store_test.go"
        ])

        let plan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(
                identifier: "TestHealth/ready",
                relativeFilePath: "cmd/api/main_test.go"
            ),
            relativeProjectFilePaths: projectFiles
        ))
        #expect(plan.frameworkID == "go")
        #expect(plan.launchPlan.executable == .toolchain("project-go"))
        #expect(plan.launchPlan.arguments == [
            "test", "./cmd/api", "-run", "^TestHealth/ready$"
        ])
        let testSession = try #require(
            capability.makeTestExecutionSession() as? GoTestExecutionSession
        )
        #expect(ObjectIdentifier(testSession) == ObjectIdentifier(session))
    }

    @Test
    func disablingGoLanguageServerWaitsForTheOwnedRuntimeProcessToStop() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            GoTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: GoLanguageServerModule.moduleManifest) {
            GoLanguageServerModule()
        })
        try await runtime.setEnabled(true, for: .languageServerExtension("go"))

        let processRegistry = GoTestLanguageServerProcessRegistry()
        let core = GoTestLanguageServerRuntimeCore(processID: 7_311)
        let runtimeFactory = GoTestLanguageProviderRuntimeFactory(
            core: core,
            processRegistry: processRegistry
        )
        let descriptor = LanguageProviderDescriptor(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "go"
        )
        let sessions = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimeFactory: runtimeFactory,
            extensionRequiredProviderIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            languageServerModuleID: GoLanguageServerModule.moduleManifest.id
        )
        let provider = try #require(
            try await runtime.activateCapability(.languageServerExtension("go"))
                as? any LanguageServerExtensionProviding
        )
        #expect(sessions.registerLanguageServerExtension(provider, support: support))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        try sessions.synchronizeLanguageServer(
            for: root.appendingPathComponent("main.go"),
            text: "package main",
            rootURL: root
        )
        #expect(processRegistry.processIDs(for: GoLanguageServerModule.moduleManifest.id) == [7_311])

        try await runtime.setEnabled(false, for: GoLanguageServerModule.moduleManifest.id)

        #expect(core.stopCalls == ["go-test-session"])
        #expect(processRegistry.processIDs(for: GoLanguageServerModule.moduleManifest.id).isEmpty)
        #expect(try runtime.snapshot(for: GoLanguageServerModule.moduleManifest.id).state == .disabled)
        #expect(try runtime.snapshot(for: GoLanguageServerModule.moduleManifest.id).activity.activeResourceCount == 0)
    }

    @Test
    func idleGoLanguageServerSleepsAndStopsItsOwnedRuntimeProcess() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            GoTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: GoLanguageServerModule.moduleManifest) {
            GoLanguageServerModule()
        })
        try await runtime.setEnabled(true, for: .languageServerExtension("go"))

        let processRegistry = GoTestLanguageServerProcessRegistry()
        let core = GoTestLanguageServerRuntimeCore(processID: 7_312)
        let runtimeFactory = GoTestLanguageProviderRuntimeFactory(
            core: core,
            processRegistry: processRegistry
        )
        let descriptor = LanguageProviderDescriptor(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "go"
        )
        let sessions = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimeFactory: runtimeFactory,
            extensionRequiredProviderIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            languageServerModuleID: GoLanguageServerModule.moduleManifest.id
        )
        let provider = try #require(
            try await runtime.activateCapability(.languageServerExtension("go"))
                as? any LanguageServerExtensionProviding
        )
        #expect(sessions.registerLanguageServerExtension(provider, support: support))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        try sessions.synchronizeLanguageServer(
            for: root.appendingPathComponent("main.go"),
            text: "package main",
            rootURL: root
        )
        let moduleID = GoLanguageServerModule.moduleManifest.id
        try runtime.markIdle(moduleID)
        let idleAt = try #require(runtime.snapshot(for: moduleID).activity.lastActivityAt)

        await runtime.evaluateIdleModules(now: idleAt.addingTimeInterval(601))

        #expect(core.stopCalls == ["go-test-session"])
        #expect(processRegistry.processIDs(for: moduleID).isEmpty)
        #expect(try runtime.snapshot(for: moduleID).state == .sleeping)
        #expect(try runtime.snapshot(for: moduleID).activity.activeResourceCount == 0)
    }
}

@MainActor
private final class GoTestWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private var capability: GoTestWorkspaceCapability?

    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {
        capability = GoTestWorkspaceCapability()
    }
    func prepareForSleep() async throws {}
    func sleep() async { capability = nil }
    func shutdown() async { capability = nil }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.workspaceFoundation: $0] } ?? [:]
    }
}

private final class GoTestWorkspaceCapability {}

@MainActor
private final class GoTestLanguageServerLifecycleState {
    var isRunning = true
    var stopCalls = 0
}

@MainActor
private final class GoTestExecutionHost: LanguageExecutionHostProviding {
    private(set) var sessions: [GoTestExecutionSession] = []

    func makeSession(ownerModuleID: ModuleID) -> any LanguageExecutionSession {
        let session = GoTestExecutionSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class GoTestExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?

    func start(_ request: LanguageExecutionProcessRequest) throws {
        isRunning = true
        onStateChange?(LanguageExecutionLifecycleEvent(
            operationID: request.operationID,
            state: .running
        ))
    }

    func stop() { isRunning = false }
}

@MainActor
private final class GoStuckExecutionHost: LanguageExecutionHostProviding {
    func makeSession(ownerModuleID _: ModuleID) -> any LanguageExecutionSession {
        GoStuckExecutionSession()
    }
}

@MainActor
private final class GoStuckExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?

    func start(_: LanguageExecutionProcessRequest) throws { isRunning = true }
    func stop() {}
    func stopAndWait() async -> Bool { false }
}

@MainActor
private final class GoTestLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
    private let core: any LanguageServerRuntimeCore
    private weak var processRegistry: (any LanguageServerProcessRegistry)?

    init(
        core: any LanguageServerRuntimeCore,
        processRegistry: any LanguageServerProcessRegistry
    ) {
        self.core = core
        self.processRegistry = processRegistry
    }

    func makeRuntime(for _: LanguageProviderDescriptor) -> (any LanguageProviderRuntime)? { nil }

    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)? {
        StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: GoTestLanguageToolRuntime(),
            languageServerLaunch: languageServerLaunch,
            languageServerCore: core,
            languageServerExecutableResolver: { _ in
                URL(fileURLWithPath: "/fixture/gopls")
            },
            processRegistry: processRegistry,
            moduleID: ownerModuleID
        )
    }
}

private final class GoTestLanguageToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment() -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { "Missing \(name)." }
}

@MainActor
private final class GoTestLanguageServerProcessRegistry: LanguageServerProcessRegistry {
    private var entries: [ModuleID: Set<Int32>] = [:]

    func registerLanguageServerProcess(pid: Int32, moduleID: ModuleID) {
        entries[moduleID, default: []].insert(pid)
    }

    func unregisterLanguageServerProcess(pid: Int32, moduleID: ModuleID) {
        entries[moduleID]?.remove(pid)
    }

    func processIDs(for moduleID: ModuleID) -> Set<Int32> {
        entries[moduleID] ?? []
    }
}

private final class GoTestLanguageServerRuntimeCore: LanguageServerRuntimeCore, @unchecked Sendable {
    private let lock = NSLock()
    private let processID: Int32
    private var pendingEvents: [LanguageServerRuntimeEvent] = []
    private(set) var stopCalls: [String] = []

    init(processID: Int32) {
        self.processID = processID
    }

    func startLanguageServer(
        providerID _: String,
        executableURL _: URL,
        arguments _: [String],
        environment _: [String: String],
        rootURL _: URL,
        workingDirectoryURL _: URL,
        initializationOptions _: ToolingJSONValue?,
        runtimeExecutableURL _: URL?,
        cacheDirectoryURL _: URL?,
        workspaceFingerprint _: String?,
        initializeTimeout _: TimeInterval,
        requestTimeout _: TimeInterval,
        shutdownTimeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        .success(LanguageServerRuntimeStart(
            sessionID: "go-test-session",
            state: "initializing",
            processID: processID
        ))
    }

    func stopLanguageServer(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        stopCalls.append(sessionID)
        pendingEvents.append(LanguageServerRuntimeEvent(type: "stateChanged", state: "stopped"))
    }

    func syncLanguageServerDocument(
        sessionID _: String,
        fileURL _: URL,
        languageID _: String,
        text _: String
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure> {
        .success(LanguageServerDocumentSync(documentVersion: 1, changed: true))
    }

    func closeLanguageServerDocument(sessionID _: String, fileURL _: URL) {}

    func requestLanguageServerOperation(
        sessionID _: String,
        operation _: LanguageServerOperation,
        fileURL _: URL?,
        virtualURI _: String?,
        position _: LanguageServerPosition?,
        newName _: String?,
        range _: LanguageServerRange?,
        diagnostics _: [LanguageServerDiagnostic],
        completionItem _: LanguageServerCompletionItem?,
        codeAction _: LanguageServerCodeAction?,
        command _: LanguageServerCommand?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .success(LanguageServerRuntimeOperation(operationID: "unused"))
    }

    func cancelLanguageServerOperation(sessionID _: String, operationID _: String) {}

    func pollLanguageServerEvents(sessionID _: String) -> [LanguageServerRuntimeEvent] {
        lock.lock(); defer { lock.unlock() }
        let events = pendingEvents
        pendingEvents.removeAll()
        return events
    }

    func destroyLanguageServer(sessionID _: String) {}
}
