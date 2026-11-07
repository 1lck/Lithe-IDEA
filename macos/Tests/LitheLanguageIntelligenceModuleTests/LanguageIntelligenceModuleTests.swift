import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

@MainActor
struct LanguageIntelligenceModuleTests {
    @Test(arguments: [false, true])
    func hostStagesAreTypedOnceAndReadyTerminationRemainLegacyOnly(cancelStartup: Bool) throws {
        let root = URL(fileURLWithPath: "/workspace/stages")
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("main.go")))
        let session = WorkspaceStateLanguageServerSession()
        let recorder = TypedLogRecorder()
        var resolutionCount = 0
        let manager = LanguageToolingSessionManager(logSink: recorder, resolveLogSubject: { provider in
            #expect(provider == "go")
            resolutionCount += 1
            return LogSegment("go")
        }, runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)])
        defer { manager.stopAllLanguageServers() }
        let operation = UUID()
        try manager.startLanguageServer(providerID: "go", rootURL: root, operationID: operation)
        if cancelStartup {
            session.publish(.initializing)
        } else {
            let count = recorder.events.count
            session.publish(.ready)
            session.onLog?(.info, "Language server is ready", nil, nil)
            session.onLog?(.info, "Language server terminated", nil, nil)
            #expect(recorder.events.count == count)
        }
        manager.stopLanguageServer(providerID: "go")
        let stages = recorder.events.compactMap { $0 as? LspSessionStageChanged }
        #expect(stages.compactMap { if case .token(let value)? = $0.fields["stage"] { return value }; return nil } == ["requested", "resolving", "registered", cancelStartup ? "cancelled" : "stopping"])
        #expect(stages.allSatisfy { $0.channel.rawValue == "lsp/go" && $0.operationID == operation.uuidString })
        #expect(!recorder.events.contains { type(of: $0).id == "lsp.session.updated" || type(of: $0).id == "lsp.protocol.initialized" })
        #expect(resolutionCount == 1)
        let terminal = CoreLogRecord(event: "lsp.session.updated", level: "DEBUG", channel: "lsp/go",
            fields: ["server": .string("go"), "state": .string("stopped")])
        session.onCoreLog?(terminal)
        #expect(recorder.coreRecords == [terminal])
    }

    @Test
    func subjectResolutionFailureIsCachedAndDoesNotAffectStartup() throws {
        let root = URL(fileURLWithPath: "/workspace/log-subject-failure")
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("main.go")))
        let session = WorkspaceStateLanguageServerSession()
        let recorder = TypedLogRecorder()
        var attempts = 0
        let manager = LanguageToolingSessionManager(logSink: recorder, resolveLogSubject: { _ in
            attempts += 1
            throw WorkspaceStateSessionError.unexpectedOperation
        }, runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)])
        defer { manager.stopAllLanguageServers() }
        try manager.startLanguageServer(providerID: "go", rootURL: root)
        session.onLogIssue?(true, "startup", "requestCancelled", nil, nil)
        manager.stopLanguageServer(providerID: "go")
        #expect(attempts == 1)
        #expect(recorder.events.isEmpty)
        #expect(session.startCallCount == 1)
    }

    @Test
    func coreLogCallbackPreservesFieldsWithoutLegacyBuffer() throws {
        let root = URL(fileURLWithPath: "/workspace/log-buffer")
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("main.go")))
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)])
        defer { manager.stopAllLanguageServers() }
        var received: [CoreLogRecord] = []
        manager.onLogEvent = { received.append($0) }
        try manager.startLanguageServer(providerID: "go", rootURL: root)
        let record = CoreLogRecord(event: "lsp.stderr.received", level: "WARN", channel: "lsp/go", op: "source-op",
            fields: ["server": .string("go"), "diagnostic": .string("upstream line")])
        session.onCoreLog?(record)
        #expect(received == [record])
        for index in 0..<105 { session.onLog?(.info, "v1 message", "projectCount=\(index)", nil) }
        #expect(received == [record])
    }

    @Test(arguments: [false, true])
    func savesFlushCurrentEditorTextAndPropagateNotificationFailures(fails: Bool) throws {
        let root = URL(fileURLWithPath: "/workspace/save")
        let file = root.appendingPathComponent("main.go")
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: file))
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(runtimes: [
            WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)
        ])
        defer { manager.stopAllLanguageServers() }
        // Saving with no active server must not start one.
        try manager.notifyDocumentSaved(file, text: "saved", currentText: "newer")
        #expect(session.startCallCount == 0)
        try manager.startLanguageServer(providerID: "go", rootURL: root)
        session.saveError = fails ? WorkspaceStateSessionError.unexpectedOperation : nil
        if fails {
            #expect(throws: WorkspaceStateSessionError.unexpectedOperation) {
                try manager.notifyDocumentSaved(file, text: "saved", currentText: "newer")
            }
        } else {
            try manager.notifyDocumentSaved(file, text: "saved", currentText: "newer")
        }
        #expect(session.documentEvents == ["sync:newer", "save:saved"])
    }

    @Test(arguments: ["main.py", "main.go", "main.rs"])
    func sessionStartupChecksCurrentPreferenceForEachWorkspace(fileName: String) throws {
        let root = URL(fileURLWithPath: "/workspace/disabled-lsp", isDirectory: true)
        let otherRoot = URL(fileURLWithPath: "/workspace/enabled-lsp", isDirectory: true)
        let file = root.appendingPathComponent(fileName)
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: file))
        let session = WorkspaceStateLanguageServerSession()
        var disabled = false
        let manager = LanguageToolingSessionManager(
            runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)],
            isLanguageServerEnabled: { providerID, workspaceURL in
                !(disabled && providerID == descriptor.id && workspaceURL == root)
            }
        )
        defer { manager.stopAllLanguageServers() }

        try manager.startLanguageServer(providerID: descriptor.id, rootURL: root)
        #expect(session.startCallCount == 1)
        disabled = true
        let error = LanguageToolingSessionError.providerDisabled(descriptor.displayName)
        // Check before reusing an existing session as well as before creating one.
        #expect(throws: error) {
            try manager.synchronizeLanguageServer(for: file, text: "", rootURL: root)
        }
        manager.stopLanguageServer(providerID: descriptor.id)
        #expect(throws: error) {
            try manager.startLanguageServer(
                providerID: descriptor.id,
                rootURL: root.appendingPathComponent("child/..", isDirectory: true)
            )
        }
        #expect(session.startCallCount == 1)

        try manager.startLanguageServer(providerID: descriptor.id, rootURL: otherRoot)
        #expect(session.startCallCount == 2)
        disabled = false
        try manager.startLanguageServer(providerID: descriptor.id, rootURL: root)
        #expect(session.startCallCount == 3)
    }

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

    /// A backend's call to its own server (plan API-35) must reach the session
    /// the manager holds. The manager stores sessions as `any
    /// LanguageServerSession`, so the two methods have to be protocol
    /// requirements; an extension-only method is dispatched statically to the
    /// default that refuses every call, and the backend sees "not running"
    /// from a server that is ready.
    @Test
    func pluginServerCallsReachTheSessionTheManagerHolds() async throws {
        let root = URL(fileURLWithPath: "/workspace/plugin-server", isDirectory: true)
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("main.go"))
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)]
        )
        defer { manager.stopAllLanguageServers() }
        try manager.startLanguageServer(providerID: "go", rootURL: root)
        session.publish(.ready)

        let request = await manager.requestPluginServer(
            pluginID: "tool", serverID: "go", method: "workspace/executeCommand", params: .null, timeout: nil
        )
        #expect(request == .success(.string("answered")))
        let notification = await manager.notifyPluginServer(
            pluginID: "tool", serverID: "go", method: "workspace/didChangeConfiguration", params: .null
        )
        #expect(notification == .success(true))
        #expect(session.pluginServerRequests == [.init(pluginID: "tool", serverID: "go", method: "workspace/executeCommand")])
        #expect(session.pluginServerNotifications == [
            .init(pluginID: "tool", serverID: "go", method: "workspace/didChangeConfiguration"),
        ])

        let absent = await manager.requestPluginServer(
            pluginID: "tool", serverID: "absent", method: "workspace/executeCommand", params: .null, timeout: nil
        )
        #expect(absent == .failure(.languageServerUnavailable))
        #expect(session.pluginServerRequests.count == 1)
    }

    /// A debugger plugin installed or removed while the app runs changes only
    /// the catalog's debug capability. The running language server keeps going;
    /// any other change to the descriptor still stops it.
    @Test
    func aDebuggerAppearingInTheCatalogDoesNotStopTheRunningLanguageServer() throws {
        func descriptor(displayName: String, capabilities: LanguageToolingCapability) -> LanguageProviderDescriptor {
            LanguageProviderDescriptor(
                id: "roc",
                displayName: displayName,
                fileExtensions: ["roc"],
                capabilities: capabilities,
                activationPolicy: .onDemand,
                languageIdentifier: "roc",
                languageServerLaunch: LanguageServerLaunchDescriptor(
                    executableNames: ["roc_language_server"],
                    arguments: []
                )
            )
        }
        let withoutDebugger = descriptor(displayName: "Roc", capabilities: [.languageServer])
        let withDebugger = descriptor(displayName: "Roc", capabilities: [.languageServer, .debugAdapter])
        let renamed = descriptor(displayName: "Roc Lang", capabilities: [.languageServer, .debugAdapter])
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [withoutDebugger]),
            runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: withoutDebugger, session: session)]
        )
        defer { manager.stopAllLanguageServers() }
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)

        try manager.startLanguageServer(providerID: "roc", rootURL: root)
        #expect(session.isRunning)

        manager.updateCatalog(LanguageProviderCatalog(descriptors: [withDebugger]))
        #expect(session.stopCallCount == 0)
        #expect(session.isRunning)

        manager.updateCatalog(LanguageProviderCatalog(descriptors: [withoutDebugger]))
        #expect(session.stopCallCount == 0)
        #expect(session.isRunning)

        manager.updateCatalog(LanguageProviderCatalog(descriptors: [renamed]))
        #expect(session.stopCallCount == 1)
        #expect(!session.isRunning)
    }

    /// Host workflows start a missing server on demand. While a module is
    /// being stopped its capability is still published, so the extension it
    /// already stopped must not be registered again; otherwise the server
    /// restarts and the module can never finish stopping.
    @Test
    func anExtensionStoppedByItsModuleIsNotRegisteredAgain() {
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
        let stopped = TestLanguageServerExtensionProvider()
        #expect(manager.registerLanguageServerExtension(stopped, support: support))

        stopped.lifecycle.stop()

        #expect(!manager.registerLanguageServerExtension(stopped, support: support))
        #expect(throws: LanguageToolingSessionError.self) {
            _ = try manager.startLanguageServer(
                providerID: "go",
                rootURL: URL(fileURLWithPath: "/workspace", isDirectory: true)
            )
        }
        #expect(manager.languageServerExtensionDescriptor(languageID: "go") == nil)
        // Reactivating the module publishes a new provider.
        #expect(manager.registerLanguageServerExtension(TestLanguageServerExtensionProvider(), support: support))
    }

    @Test
    func workspaceResetStopsTheActiveSessionBeforeResettingItsState() throws {
        let root = URL(fileURLWithPath: "/workspace/go", isDirectory: true)
        let source = root.appendingPathComponent("src/main.go")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let runtime = WorkspaceStateLanguageProviderRuntime(
            descriptor: descriptor,
            session: session
        )
        var resetRoot: URL?
        var stopCountAtReset: Int?
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [runtime],
            workspaceStateResetter: { _, rootURL in
                resetRoot = rootURL
                stopCountAtReset = session.stopCallCount
            }
        )

        try manager.synchronizeLanguageServer(
            for: source,
            text: "package main",
            rootURL: root
        )
        try manager.rebuildWorkspaceState(providerID: "go", rootURL: root)

        #expect(session.stopCallCount == 1)
        #expect(stopCountAtReset == 1)
        #expect(resetRoot == root.standardizedFileURL)
    }

    @Test
    func languageServerLifecycleLogsAndCallbacksRetainTheOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/go", isDirectory: true)
        let source = root.appendingPathComponent("main.go")
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
            guard providerID == "go" else { return }
            callbacks.append((state, callbackOperationID))
        }

        try manager.startLanguageServer(
            providerID: "go",
            rootURL: root,
            operationID: operationID
        )
        session.publish(.ready)
        manager.stopLanguageServer(providerID: "go")

        #expect(callbacks.contains { $0.0 == .ready && $0.1 == operationID })
        #expect(callbacks.contains { $0.0 == .stopped && $0.1 == operationID })
        #expect(manager.languageServerOperationIDs["go"] == nil)
    }

    @Test
    func languageServerStartTimeoutIsLoggedWithTheOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/go", isDirectory: true)
        let source = root.appendingPathComponent("main.go")
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
                providerID: "go",
                rootURL: root,
                operationID: operationID
            )
        }

        #expect(manager.languageServerStates["go"] == .failed(timeoutFailure))
    }

    /// Regression for LSP-08: macOS used a private three-attempt counter while
    /// Windows used a five-second cooldown. Both now apply Core's decision.
    @Test
    func automaticStartsApplyTheCoreActivationDecision() throws {
        let root = URL(fileURLWithPath: "/workspace/go-activation", isDirectory: true)
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("main.go"))
        )
        let session = WorkspaceStateLanguageServerSession()
        let failure = LanguageServerSessionFailure(code: "start_failed", stage: "processStart", message: "boom")
        session.startError = LanguageServerSessionStartError(failure: failure)
        let history = LanguageServerActivationState(consecutiveFailures: 1, lastFailureAtMs: 1000)
        let policy = ScriptedActivationPolicy(outcomes: [
            .init(state: nil, decision: .allow, retryAfterMs: nil),
            .init(state: history, decision: .wait, retryAfterMs: 5000),
            .init(state: history, decision: .wait, retryAfterMs: 1),
            .init(state: nil, decision: .allow, retryAfterMs: nil),
            .init(state: nil, decision: .allow, retryAfterMs: nil),
        ])
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)],
            policyCore: policy
        )
        defer { manager.stopAllLanguageServers() }
        var now: UInt64 = 1000
        manager.monotonicNowMs = { now }

        #expect(throws: LanguageServerSessionStartError.self) {
            try manager.startLanguageServer(providerID: "go", rootURL: root)
        }
        now = 5999
        // A waiting decision reports the previous failure without a new process.
        let waiting = #expect(throws: LanguageServerSessionStartError.self) {
            try manager.startLanguageServer(providerID: "go", rootURL: root)
        }
        #expect(waiting?.failure == failure)
        #expect(session.startCallCount == 1)

        // An explicit stop forgets the history, so the next start sends none.
        manager.stopLanguageServer(providerID: "go")
        session.startError = nil
        now = 6000
        try manager.startLanguageServer(providerID: "go", rootURL: root)
        session.publish(.ready)
        #expect(session.startCallCount == 2)

        #expect(policy.requests == [
            .init(state: nil, event: .automaticStart, nowMs: 1000),
            .init(state: nil, event: .startFailed, nowMs: 1000),
            .init(state: history, event: .automaticStart, nowMs: 5999),
            .init(state: nil, event: .automaticStart, nowMs: 6000),
            .init(state: nil, event: .ready, nowMs: 6000),
        ])
    }

    @Test
    func sessionIssuesPreserveWarningStageCodeAndExitStatus() throws {
        let root = URL(fileURLWithPath: "/workspace/go")
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("main.go")))
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)])
        defer { manager.stopAllLanguageServers() }
        var facts: [(Bool, String, String, Int?)] = []
        manager.onLogIssue = { _, _, warning, stage, code, exit in facts.append((warning, stage, code, exit)) }
        try manager.startLanguageServer(providerID: "go", rootURL: root)
        for (warning, stage, code, exit) in [(true, "transport", "inputBlocked", nil),
            (true, "configuration", "configurationFailed", nil), (false, "initialize", "initializeTimeout", 7)] {
            session.onLogIssue?(warning, stage, code, exit, "operation-1")
        }
        #expect(facts.count == 3)
        #expect(facts.map { $0.2 } == ["inputBlocked", "configurationFailed", "initializeTimeout"])
        #expect(facts.last?.3 == 7)
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

    // MARK: - Debug adapters hosted by a language server

    @Test(arguments: HostedDebugPortOutcome.allCases)
    func aHostedDebugAdapterWaitsForItsServerAndRejectsCancelledOrStalePorts(outcome: HostedDebugPortOutcome) async throws {
        let root = URL(fileURLWithPath: "/workspace/hosted-adapter", isDirectory: true)
        let session = WorkspaceStateLanguageServerSession()
        let factory = TestLanguageProviderRuntimeFactory()
        factory.session = session
        let manager = LanguageToolingSessionManager(runtimeFactory: factory)
        let provider = TestLanguageServerExtensionProvider(configuration: .init(
            languageID: "go", displayName: "Go", executableNames: ["example-ls"], languageIdentifier: "go",
            launchSource: .init(pluginID: "dev.example.debugger", languageID: "go", manifest: Data(),
                                packageURL: URL(fileURLWithPath: "/plugins/example"))
        ))
        let support = LanguageSupportDeclaration(
            id: "go", displayName: "Go", fileExtensions: ["go"], languageServerModuleID: .languageServerExtension("go")
        )
        try #require(manager.registerLanguageServerExtension(provider, support: support))
        let (events, continuation) = AsyncStream<Result<UInt16, Error>>.makeStream()
        let task = Task { @MainActor in
            do {
                continuation.yield(.success(try await manager.startHostedDebugAdapter(
                    languageID: "go", pluginID: "dev.example.debugger", command: "example.start", rootURL: root
                )))
            } catch { continuation.yield(.failure(error)) }
            continuation.finish()
        }
        let deadline = Task { @MainActor in
            // test-stability: allow(swift-real-sleep) reason: this is only the local failure watchdog; server and command callbacks drive successful synchronization.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            task.cancel()
            continuation.finish()
        }
        defer { task.cancel(); deadline.cancel(); continuation.finish(); manager.stopAllLanguageServers() }
        try await session.waitUntilStarted()
        #expect(session.executedCommands.isEmpty)
        if outcome == .cancelBeforeReady {
            task.cancel()
        } else {
            session.publish(.ready)
            let command = try await session.waitForExecuteCommand()
            #expect(command.command == "example.start")
            #expect(command.arguments.isEmpty)
            if outcome == .cancelCommand {
                task.cancel()
            } else {
                // Capture the reply before replacing the server to model a
                // response already in flight when the workspace changes.
                try session.completeExecuteReturningValue(.success(.string("4711"))) {
                    switch outcome {
                    case .workspaceChanged:
                        try manager.startLanguageServer(
                            providerID: "go", rootURL: root.appendingPathComponent("other", isDirectory: true)
                        )
                        session.publish(.ready)
                    case .sessionReplaced:
                        let replacement = WorkspaceStateLanguageServerSession()
                        factory.session = replacement
                        try #require(manager.registerLanguageServerExtension(
                            TestLanguageServerExtensionProvider(configuration: provider.configuration), support: support
                        ))
                        try manager.startLanguageServer(providerID: "go", rootURL: root)
                        replacement.publish(.ready)
                    case .stopping: session.publish(.stopping)
                    default: break
                    }
                }
            }
        }
        var iterator = events.makeAsyncIterator()
        let result = try #require(await iterator.next(), "Hosted debugging did not finish before its deadline")
        switch outcome {
        case .cancelBeforeReady, .cancelCommand:
            guard case .failure(let error) = result else {
                Issue.record("A cancelled port request must not succeed")
                return
            }
            #expect(error is CancellationError)
            // Delivering a late port must not complete the cancelled operation twice.
            session.completeExecuteReturningValue(.success(.integer(4711)))
        case .success:
            #expect(try result.get() == 4711)
        case .workspaceChanged, .sessionReplaced, .stopping:
            guard case .failure(let error) = result else {
                Issue.record("A stale port must not be returned to the debug transport")
                return
            }
            #expect(error as? LanguageToolingSessionError == .languageServerNotOwnedByPlugin(languageID: "go"))
        }
        await task.value
        if outcome != .workspaceChanged && outcome != .sessionReplaced {
            #expect(session.isRunning)
            #expect(session.stopCallCount == 0)
        }
    }

    /// The command's result is the loopback port: an integer, or the digits
    /// of one in a string, within 1...65535. Anything else is no port.
    @Test(arguments: [
        (ToolingJSONValue.integer(5005), UInt16?.some(5005)),
        (.integer(1), 1),
        (.integer(65535), 65535),
        (.string("5005"), 5005),
        (.integer(0), nil),
        (.integer(-1), nil),
        (.integer(65536), nil),
        (.string("65536"), nil),
        (.string("port"), nil),
        (.string(""), nil),
        (.string("5005 "), nil),
        (.number(5005.5), nil),
        (.bool(true), nil),
        (.null, nil),
        (.array([.integer(5005)]), nil),
        (.object(["port": .integer(5005)]), nil),
    ])
    func aDebugAdapterPortIsOnlyAnIntegerWithinTheTCPRange(
        value: ToolingJSONValue,
        expected: UInt16?
    ) {
        #expect(LanguageToolingSessionManager.debugAdapterPort(from: value) == expected)
    }

    /// Only the language server of the plugin that declared the adapter may
    /// receive its command; a server the plugin did not register, here a
    /// built-in one, is refused before anything starts.
    @Test
    func aHostedDebugAdapterIsRefusedForALanguageServerThePluginDoesNotOwn() async throws {
        let root = URL(fileURLWithPath: "/workspace/hosted-adapter", isDirectory: true)
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("main.go")))
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(runtimes: [WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session)])
        defer { manager.stopAllLanguageServers() }

        await #expect(throws: LanguageToolingSessionError.languageServerNotOwnedByPlugin(languageID: "go")) {
            _ = try await manager.startHostedDebugAdapter(
                languageID: "go", pluginID: "dev.lithe.fixture", command: "example.start", rootURL: root
            )
        }
        #expect(session.startCallCount == 0)
    }
}

enum HostedDebugPortOutcome: CaseIterable {
    case success, cancelBeforeReady, cancelCommand, workspaceChanged, sessionReplaced, stopping
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
    func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] { [:] }
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
    var session: WorkspaceStateLanguageServerSession?

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
        if let session { return WorkspaceStateLanguageProviderRuntime(descriptor: descriptor, session: session) }
        return TestLanguageProviderRuntime(descriptor: descriptor)
    }
}

/// Records activation requests and answers with scripted Core outcomes; the
/// policy itself is covered by the shared fixture in Rust Core.
private final class ScriptedActivationPolicy: LanguageToolingPolicyCore, @unchecked Sendable {
    struct Request: Equatable {
        let state: LanguageServerActivationState?
        let event: LanguageServerActivationEvent
        let nowMs: UInt64
    }

    private(set) var requests: [Request] = []
    private var outcomes: [LanguageServerActivationOutcome]

    init(outcomes: [LanguageServerActivationOutcome]) { self.outcomes = outcomes }

    func languageServerActivation(
        state: LanguageServerActivationState?, event: LanguageServerActivationEvent, nowMs: UInt64
    ) -> Result<LanguageServerActivationOutcome, LanguageToolingPolicyFailure> {
        requests.append(Request(state: state, event: event, nowMs: nowMs))
        guard !outcomes.isEmpty else { return .failure(LanguageToolingPolicyFailure(code: "unscripted")) }
        return .success(outcomes.removeFirst())
    }

    func mergeCompletions(
        labels _: [[String]], incomplete _: [Bool]
    ) -> Result<CompletionMergeSelection, LanguageToolingPolicyFailure> {
        .failure(LanguageToolingPolicyFailure(code: "unscripted"))
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
    var onCoreLog: ((CoreLogRecord) -> Void)?
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)?
    var onLogIssue: ((Bool, String, String, Int?, String?) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    var features: LanguageServerFeatureSet = []
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    var serverInfo: LanguageServerInfo?
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)?
    private(set) var stopCallCount = 0
    private(set) var startCallCount = 0
    var startError: Error?
    private(set) var executedCommands: [LanguageServerCommand] = []
    private var startWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var startTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var executeWaiters: [UUID: (
        number: Int,
        continuation: CheckedContinuation<LanguageServerCommand, Error>
    )] = [:]
    private var executeTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var executeValueCompletion: ((Result<ToolingJSONValue, Error>) -> Void)?
    struct PluginServerCall: Equatable {
        let pluginID: String
        let serverID: String
        let method: String
    }
    private(set) var pluginServerRequests: [PluginServerCall] = []
    private(set) var pluginServerNotifications: [PluginServerCall] = []

    func requestPluginServer(
        pluginID: String, serverID: String, method: String, params _: ToolingJSONValue, timeout _: TimeInterval?
    ) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        pluginServerRequests.append(PluginServerCall(pluginID: pluginID, serverID: serverID, method: method))
        return .success(.string("answered"))
    }

    func notifyPluginServer(
        pluginID: String, serverID: String, method: String, params _: ToolingJSONValue
    ) async -> Result<Bool, PluginHostRequestFailure> {
        pluginServerNotifications.append(PluginServerCall(pluginID: pluginID, serverID: serverID, method: method))
        return .success(true)
    }

    func start(rootURL _: URL) throws {
        startCallCount += 1
        if let startError { throw startError }
        isRunning = true
        let waiterIDs = Array(startWaiters.keys)
        waiterIDs.forEach { finishStartWaiter($0, result: .success(())) }
    }

    func publish(_ state: LanguageServerSessionState) {
        onStateChange?(state)
    }

    func waitUntilStarted(timeout: Duration = .seconds(2)) async throws {
        if isRunning { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !isRunning else {
                    continuation.resume()
                    return
                }
                startWaiters[waiterID] = continuation
                let timeoutTask = Task { @MainActor [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: this watchdog bounds a failed continuation wait while successful synchronization remains event-driven.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishStartWaiter(
                        waiterID,
                        result: .failure(WorkspaceStateSessionError.timedOut)
                    )
                }
                if startWaiters[waiterID] == nil {
                    timeoutTask.cancel()
                } else {
                    startTimeoutTasks[waiterID] = timeoutTask
                }
                if Task.isCancelled {
                    finishStartWaiter(waiterID, result: .failure(CancellationError()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishStartWaiter(waiterID, result: .failure(CancellationError()))
            }
        }
    }

    func waitForExecuteCommand(
        number: Int = 1,
        timeout: Duration = .seconds(2)
    ) async throws -> LanguageServerCommand {
        precondition(number > 0)
        if executedCommands.count >= number { return executedCommands[number - 1] }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard executedCommands.count < number else {
                    continuation.resume(returning: executedCommands[number - 1])
                    return
                }
                executeWaiters[waiterID] = (number, continuation)
                let timeoutTask = Task { @MainActor [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: this watchdog bounds a failed continuation wait while successful synchronization remains event-driven.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishExecuteWaiter(
                        waiterID,
                        result: .failure(WorkspaceStateSessionError.timedOut)
                    )
                }
                if executeWaiters[waiterID] == nil {
                    timeoutTask.cancel()
                } else {
                    executeTimeoutTasks[waiterID] = timeoutTask
                }
                if Task.isCancelled {
                    finishExecuteWaiter(waiterID, result: .failure(CancellationError()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishExecuteWaiter(waiterID, result: .failure(CancellationError()))
            }
        }
    }

    func completeExecuteReturningValue(_ result: Result<ToolingJSONValue, Error>) {
        completeExecuteReturningValue(result, beforeCompletion: {})
    }

    func completeExecuteReturningValue(
        _ result: Result<ToolingJSONValue, Error>,
        beforeCompletion: () throws -> Void
    ) rethrows {
        let completion = executeValueCompletion
        executeValueCompletion = nil
        try beforeCompletion()
        completion?(result)
    }

    var documentEvents: [String] = []
    var saveError: Error?
    func synchronize(fileURL _: URL, text: String, languageID _: String) throws {
        documentEvents.append("sync:\(text)")
    }
    func notifyDocumentSaved(_ fileURL: URL, text: String) throws {
        documentEvents.append("save:\(text)")
        if let saveError { throw saveError }
    }
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

    func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL _: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws {
        executeValueCompletion = completion
        recordExecutedCommand(command)
    }

    private func recordExecutedCommand(_ command: LanguageServerCommand) {
        executedCommands.append(command)
        let readyWaiterIDs = executeWaiters.compactMap { waiterID, waiter in
            waiter.number <= executedCommands.count ? waiterID : nil
        }
        readyWaiterIDs.forEach { waiterID in
            guard let waiter = executeWaiters[waiterID] else { return }
            finishExecuteWaiter(
                waiterID,
                result: .success(executedCommands[waiter.number - 1])
            )
        }
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
        Array(startWaiters.keys).forEach {
            finishStartWaiter($0, result: .failure(CancellationError()))
        }
        Array(executeWaiters.keys).forEach {
            finishExecuteWaiter($0, result: .failure(CancellationError()))
        }
        let completion = executeValueCompletion
        executeValueCompletion = nil
        completion?(.failure(CancellationError()))
    }

    private func finishStartWaiter(_ waiterID: UUID, result: Result<Void, Error>) {
        let continuation = startWaiters.removeValue(forKey: waiterID)
        let timeoutTask = startTimeoutTasks.removeValue(forKey: waiterID)
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }

    private func finishExecuteWaiter(
        _ waiterID: UUID,
        result: Result<LanguageServerCommand, Error>
    ) {
        let waiter = executeWaiters.removeValue(forKey: waiterID)
        let timeoutTask = executeTimeoutTasks.removeValue(forKey: waiterID)
        timeoutTask?.cancel()
        waiter?.continuation.resume(with: result)
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
    let configuration: LanguageServerExtensionConfiguration
    init(configuration: LanguageServerExtensionConfiguration = LanguageServerExtensionConfiguration(
        languageID: "go",
        displayName: "Go",
        executableNames: ["gopls"],
        languageIdentifier: "go"
    )) { self.configuration = configuration }
    let lifecycle: any LanguageServerExtensionLifecycle = TestLanguageServerExtensionLifecycle()
}

@MainActor
private final class TestLanguageServerExtensionLifecycle: LanguageServerExtensionLifecycle {
    private var running: @MainActor () -> Bool = { false }
    private var stopAction: @MainActor () -> Void = {}
    private(set) var isRetired = false
    var isRunning: Bool { running() }
    func attach(
        isRunning: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        running = isRunning
        stopAction = stop
    }
    func stop() {
        isRetired = true
        stopAction()
    }
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

private final class TypedLogRecorder: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any LogEvent] = []
    var events: [any LogEvent] { lock.withLock { values } }
    func emit(_ event: any LogEvent) { lock.withLock { values.append(event) } }
    private var coreValues: [CoreLogRecord] = []
    var coreRecords: [CoreLogRecord] { lock.withLock { coreValues } }
    func emit(_ record: CoreLogRecord) { lock.withLock { coreValues.append(record) } }
}
