import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import LithePhpSupportModule
import Testing

@MainActor
struct PhpSupportModuleTests {
    @Test
    func lspAndExecutionActivateAndDisableIndependently() async throws {
        let runtime = ModuleRuntime()
        let executionHost = PhpTestExecutionHost()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            PhpTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: PhpLanguageServerModule.moduleManifest) {
            PhpLanguageServerModule()
        })
        try runtime.register(ModuleFactory(manifest: PhpExecutionModule.moduleManifest) {
            PhpExecutionModule(executionHost: executionHost)
        })
        try runtime.validateGraph()
        try await runtime.setEnabled(true, for: .languageServerExtension("php"))
        try await runtime.setEnabled(true, for: .languageExecutionExtension("php"))

        let lsp = try await runtime.activateCapability(.languageServerExtension("php"))
        let execution = try await runtime.activateCapability(.languageExecutionExtension("php"))
        let testing = try await runtime.activateCapability(.languageTestingExtension("php"))
        #expect(lsp is PhpLanguageServerCapability)
        #expect(execution is PhpExecutionCapability)
        let testingCapability = try #require(testing as? PhpExecutionCapability)
        let executionObject = try #require(execution as? PhpExecutionCapability)
        #expect(ObjectIdentifier(testingCapability) == ObjectIdentifier(executionObject))

        let lspCapability = try #require(lsp as? PhpLanguageServerCapability)
        let lspLifecycle = PhpTestLanguageServerLifecycleState()
        lspCapability.lifecycle.attach(
            isRunning: { lspLifecycle.isRunning },
            stop: {
                lspLifecycle.isRunning = false
                lspLifecycle.stopCalls += 1
            }
        )

        try await runtime.setEnabled(false, for: .languageServerExtension("php"))
        #expect(lspLifecycle.stopCalls == 1)
        #expect(!lspLifecycle.isRunning)
        #expect(try runtime.snapshot(for: .languageServerExtension("php")).state == .disabled)
        #expect(try runtime.snapshot(for: .languageServerExtension("php")).activity.activeResourceCount == 0)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("php")).state == .active)

        let executionCapability = try #require(execution as? PhpExecutionCapability)
        let executionSession = executionCapability.makeExecutionSession()
        let testSession = executionCapability.makeTestExecutionSession()
        try executionSession.start(LanguageExecutionProcessRequest(
            executablePath: "/fixture/php",
            arguments: ["bin/console.php"]
        ))
        try testSession.start(LanguageExecutionProcessRequest(
            executablePath: "/fixture/php",
            arguments: ["vendor/bin/phpunit"]
        ))
        #expect(executionSession.isRunning)
        #expect(testSession.isRunning)
        #expect(executionHost.sessions.count == 2)

        try await runtime.setEnabled(false, for: .languageExecutionExtension("php"))
        #expect(!executionSession.isRunning)
        #expect(!testSession.isRunning)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("php")).activity.activeResourceCount == 0)
    }

    @Test
    func executionDisableFailsWhenAnOwnedProcessCannotBeStopped() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            PhpTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: PhpExecutionModule.moduleManifest) {
            PhpExecutionModule(executionHost: PhpStuckExecutionHost())
        })
        try await runtime.setEnabled(true, for: .languageExecutionExtension("php"))

        let capability = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("php"))
                as? any LanguageRunExtensionProviding
        )
        let session = capability.makeExecutionSession()
        try session.start(LanguageExecutionProcessRequest(executablePath: "/fixture/php"))

        await #expect(throws: ModuleRuntimeError.activeResourcesRemain(
            module: .languageExecutionExtension("php"),
            kinds: ["language-execution-process"]
        )) {
            try await runtime.setEnabled(false, for: .languageExecutionExtension("php"))
        }
        let snapshot = try runtime.snapshot(for: .languageExecutionExtension("php"))
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
            PhpTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: PhpExecutionModule.moduleManifest) {
            PhpExecutionModule(executionHost: PhpTestExecutionHost())
        })
        try await runtime.setEnabled(true, for: .languageExecutionExtension("php"))

        let capability = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("php"))
                as? any LanguageRunExtensionProviding
        )
        let session = capability.makeExecutionSession()
        try session.start(LanguageExecutionProcessRequest(
            operationID: "php-run",
            executablePath: "/fixture/php"
        ))
        let moduleID = ModuleID.languageExecutionExtension("php")
        #expect(try runtime.snapshot(for: moduleID).activity.activeLeaseCount == 1)
        await #expect(throws: ModuleRuntimeError.activeLeasesPreventSleep(
            module: moduleID,
            reasons: ["Language execution php-run"]
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
    func phpExecutionProducesAWorkspaceRelativeCommandPlan() throws {
        let capability = PhpExecutionCapability(executionSession: PhpTestExecutionSession())
        let plan = try capability.launchPlan(for: LanguageRunExtensionRequest(
            relativeFilePath: "public/index.php",
            arguments: ["--env", "dev"],
            environment: ["APP_ENV": "dev"]
        ))

        // PHP has no shared run toolchain, so the plan must use the PHP binary
        // the user already has on PATH.
        #expect(plan.executable == .command("php"))
        #expect(plan.arguments == ["public/index.php", "--env", "dev"])
        #expect(plan.workingDirectory == ".")
        #expect(plan.environment == ["APP_ENV": "dev"])
    }

    @Test
    func phpExecutionPreservesFileNamesAndProtectsLeadingOptions() throws {
        let capability = PhpExecutionCapability(executionSession: PhpTestExecutionSession())
        for (path, expected) in [(" index.php", " index.php"), ("index.php ", "index.php "), ("-file.php", "./-file.php")] {
            let plan = try capability.launchPlan(for: LanguageRunExtensionRequest(relativeFilePath: path))
            #expect(plan.arguments == [expected])
        }
    }

    @Test
    func phpExecutionRejectsPathsOutsideTheWorkspace() {
        let capability = PhpExecutionCapability(executionSession: PhpTestExecutionSession())
        #expect(throws: LanguageRunExtensionError.invalidRelativePath) {
            _ = try capability.launchPlan(for: LanguageRunExtensionRequest(
                relativeFilePath: "../outside.php"
            ))
        }
    }

    @Test
    func phpTestingDiscoversFilesAndBuildsAPhpUnitPlan() throws {
        let session = PhpTestExecutionSession()
        let capability = PhpExecutionCapability(executionSession: session)
        let projectFiles = [
            "composer.json",
            "src/Health.php",
            "src/HealthTest.php",
            "tests/StoreTest.php"
        ]

        let items = try capability.discoverTests(for: LanguageTestExtensionDiscoveryRequest(
            relativeProjectFilePaths: projectFiles
        ))
        #expect(items.map(\.id) == [
            "php:workspace",
            "php:file:src/HealthTest.php",
            "php:file:tests/StoreTest.php"
        ])

        let plan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(
                identifier: "testKeepsInsertionOrder",
                relativeFilePath: "tests/StoreTest.php"
            ),
            relativeProjectFilePaths: projectFiles
        ))
        #expect(plan.frameworkID == "phpunit")
        #expect(plan.launchPlan.executable == .command("php"))
        // Word boundaries, not anchors: PHPUnit matches `--filter` against the full
        // `Class::method` ID, so `^name$` would run nothing at all.
        #expect(plan.launchPlan.arguments == [
            "vendor/bin/phpunit", "--filter", "\\btestKeepsInsertionOrder\\b", "tests/StoreTest.php"
        ])

        let workspacePlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .workspace,
            relativeProjectFilePaths: projectFiles
        ))
        #expect(workspacePlan.frameworkID == "phpunit")
        #expect(workspacePlan.launchPlan.arguments == ["vendor/bin/phpunit"])
        let testSession = try #require(
            capability.makeTestExecutionSession() as? PhpTestExecutionSession
        )
        #expect(ObjectIdentifier(testSession) == ObjectIdentifier(session))
    }

    @Test
    func phpTestingReportsNoTestsOutsideAPhpUnitProject() throws {
        let capability = PhpExecutionCapability(executionSession: PhpTestExecutionSession())
        let projectFiles = ["README.md", "src/HealthTest.php"]

        let items = try capability.discoverTests(for: LanguageTestExtensionDiscoveryRequest(
            relativeProjectFilePaths: projectFiles
        ))
        #expect(items.isEmpty)
        #expect(throws: LanguageTestExtensionError.unsupportedProject(languageID: "php")) {
            _ = try capability.testPlan(for: LanguageTestExtensionRequest(
                scope: .workspace,
                relativeProjectFilePaths: projectFiles
            ))
        }
    }

    @Test
    func disablingPhpLanguageServerWaitsForTheOwnedRuntimeProcessToStop() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            PhpTestWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: PhpLanguageServerModule.moduleManifest) {
            PhpLanguageServerModule()
        })
        try await runtime.setEnabled(true, for: .languageServerExtension("php"))

        let processRegistry = PhpTestLanguageServerProcessRegistry()
        let core = PhpTestLanguageServerRuntimeCore(processID: 9_411)
        let runtimeFactory = PhpTestLanguageProviderRuntimeFactory(
            core: core,
            processRegistry: processRegistry
        )
        let descriptor = LanguageProviderDescriptor(
            id: "php",
            displayName: "PHP",
            fileExtensions: ["php"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "php"
        )
        let sessions = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimeFactory: runtimeFactory,
            extensionRequiredProviderIDs: ["php"]
        )
        let support = LanguageSupportDeclaration(
            id: "php",
            displayName: "PHP",
            fileExtensions: ["php"],
            languageServerModuleID: PhpLanguageServerModule.moduleManifest.id
        )
        let provider = try #require(
            try await runtime.activateCapability(.languageServerExtension("php"))
                as? any LanguageServerExtensionProviding
        )
        // The plugin is the only source of truth for the launch arguments, while
        // the shared catalog feeds the language-server settings UI. Both must
        // describe the same executable and the same stdio mode.
        #expect(provider.configuration.executableNames == ["intelephense"])
        #expect(provider.configuration.arguments == ["--stdio"])
        #expect(sessions.registerLanguageServerExtension(provider, support: support))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        try sessions.synchronizeLanguageServer(
            for: root.appendingPathComponent("index.php"),
            text: "<?php",
            rootURL: root
        )
        #expect(processRegistry.processIDs(for: PhpLanguageServerModule.moduleManifest.id) == [9_411])

        try await runtime.setEnabled(false, for: PhpLanguageServerModule.moduleManifest.id)

        #expect(core.stopCalls == ["php-test-session"])
        #expect(processRegistry.processIDs(for: PhpLanguageServerModule.moduleManifest.id).isEmpty)
        #expect(try runtime.snapshot(for: PhpLanguageServerModule.moduleManifest.id).state == .disabled)
        #expect(try runtime.snapshot(for: PhpLanguageServerModule.moduleManifest.id).activity.activeResourceCount == 0)
    }
}

@MainActor
private final class PhpTestWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private var capability: PhpTestWorkspaceCapability?

    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {
        capability = PhpTestWorkspaceCapability()
    }
    func prepareForSleep() async throws {}
    func sleep() async { capability = nil }
    func shutdown() async { capability = nil }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.workspaceFoundation: $0] } ?? [:]
    }
}

private final class PhpTestWorkspaceCapability {}

@MainActor
private final class PhpTestLanguageServerLifecycleState {
    var isRunning = true
    var stopCalls = 0
}

@MainActor
private final class PhpTestExecutionHost: LanguageExecutionHostProviding {
    private(set) var sessions: [PhpTestExecutionSession] = []

    func makeSession(ownerModuleID: ModuleID) -> any LanguageExecutionSession {
        let session = PhpTestExecutionSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class PhpTestExecutionSession: LanguageExecutionSession {
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
private final class PhpStuckExecutionHost: LanguageExecutionHostProviding {
    func makeSession(ownerModuleID _: ModuleID) -> any LanguageExecutionSession {
        PhpStuckExecutionSession()
    }
}

@MainActor
private final class PhpStuckExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?

    func start(_: LanguageExecutionProcessRequest) throws { isRunning = true }
    func stop() {}
    func stopAndWait() async -> Bool { false }
}

@MainActor
private final class PhpTestLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
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
            runtimeService: PhpTestLanguageToolRuntime(),
            languageServerLaunch: languageServerLaunch,
            languageServerCore: core,
            languageServerExecutableResolver: { _ in
                URL(fileURLWithPath: "/fixture/intelephense")
            },
            processRegistry: processRegistry,
            moduleID: ownerModuleID
        )
    }
}

private final class PhpTestLanguageToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment() -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { "Missing \(name)." }
}

@MainActor
private final class PhpTestLanguageServerProcessRegistry: LanguageServerProcessRegistry {
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

private final class PhpTestLanguageServerRuntimeCore: LanguageServerRuntimeCore, @unchecked Sendable {
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
        jdtlsLaunchResources _: JDTLSLaunchResources?,
        cacheDirectoryURL _: URL?,
        workspaceFingerprint _: String?,
        initializeTimeout _: TimeInterval,
        requestTimeout _: TimeInterval,
        shutdownTimeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        .success(LanguageServerRuntimeStart(
            sessionID: "php-test-session",
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
