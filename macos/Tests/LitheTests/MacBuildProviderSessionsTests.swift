import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

/// The real provider process table with a scripted runtime core: the
/// process a request reuses, and when the host stops or restarts it.
@MainActor
struct MacBuildProviderSessionsTests {
    @Test(arguments: [false, true])
    func documentSavesReachCoreAndPropagateTransportFailure(fails: Bool) async throws {
        let core = ScriptedProviderCore()
        let session = LanguageServerRuntimeSession(
            providerID: "java", executableURL: URL(fileURLWithPath: "/tools/jdtls"),
            arguments: [], environment: [:], core: core)
        let file = URL(fileURLWithPath: "/workspace/Main.java")
        defer { session.stop() }
        try session.notifyDocumentSaved(file, text: "before startup")
        #expect(core.savedTexts.isEmpty)
        try session.start(rootURL: file.deletingLastPathComponent(), workspaceFingerprint: nil)
        core.saveFails = fails
        if fails {
            #expect(throws: (any Error).self) { try session.notifyDocumentSaved(file, text: "saved") }
        } else {
            try session.notifyDocumentSaved(file, text: "saved")
        }
        #expect(core.savedTexts == ["saved"])
        #expect(core.syncedTexts.isEmpty)
        session.stop()
        try #require(await core.destroyed.waitUntilOpen())
    }

    @Test(arguments: [false, true], [false, true])
    func javaLaunchPreparationDecodesSharedTargetsAndCancelsItsOwnedOperation(cancel: Bool, buildFailed: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable {
            struct Case: Decodable { let target: JavaDebugLaunchTarget }
            let cases: [Case]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/lsp/java-launch-preparation-v1.json")))
        for item in fixture.cases {
            let core = ScriptedProviderCore()
            let session = LanguageServerRuntimeSession(
                providerID: "java", executableURL: URL(fileURLWithPath: "/tools/jdtls"),
                arguments: [], environment: [:], core: core
            )
            let workspace = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
            try session.start(rootURL: workspace, workspaceFingerprint: nil)
            let finished = TestGate()
            let request = Task { @MainActor () -> Result<JavaLaunchPreparation, Error> in
                defer { finished.open() }
                do { return .success(try await session.prepareJavaLaunch(
                    fileURL: workspace.appendingPathComponent("Main.java"), mainClass: "demo.Main"
                )) } catch { return .failure(error) }
            }
            defer { request.cancel(); session.stop() }
            try #require(await core.commandStarted.waitUntilOpen())
            if cancel {
                request.cancel()
                try #require(await core.functionCancelled.waitUntilOpen())
            } else {
                let target = try JSONDecoder().decode(ToolingJSONValue.self, from: JSONEncoder().encode(item.target))
                var result: [String: ToolingJSONValue] = [
                    "kind": .string(buildFailed ? "buildFailed" : "ready"), "target": target
                ]
                if buildFailed {
                    result["failure"] = .object([
                        "code": .string("javaBuildCompilationErrors"),
                        "message": .string("The Java project build reported compilation errors."),
                        "report": .object(["markerScope": .string("launchTarget"),
                            "builderFailedEarlier": .bool(false), "elapsedMilliseconds": .integer(25),
                            "recovery": .string("rebuildJavaIndex")])
                    ])
                }
                core.finishJavaLaunch(.object(result))
            }
            try #require(await finished.waitUntilOpen(), "Java launch did not finish before its local deadline")
            switch await request.value {
            case .success(let preparation):
                #expect(!cancel)
                if buildFailed {
                    guard case .buildFailed(let target, let failure) = preparation else {
                        Issue.record("A terminal build failure must retain its evidence and launch target")
                        return
                    }
                    #expect(target == item.target)
                    #expect(failure.code == "javaBuildCompilationErrors")
                    #expect(failure.message == L10n.string("The Java project build reported compilation errors."))
                    #expect(failure.report?.elapsedMilliseconds == 25)
                    #expect(failure.report?.recovery == .rebuildJavaIndex)
                } else {
                    #expect(preparation == .ready(item.target))
                }
            case .failure(let error):
                #expect(cancel)
                #expect(error is CancellationError)
                #expect(core.cancelledOperations == ["java-launch"])
            }
            #expect(session.isRunning)
            #expect(core.stopCalls.isEmpty)
            session.stop()
            try #require(await core.destroyed.waitUntilOpen())
        }
    }

    @Test
    func preparedPluginKeepsConfigurationAndQueuedWorkspaceChanges() async throws {
        let core = ScriptedProviderCore()
        let preparing = TestGate()
        let resume = TestGate()
        let released = TestGate()
        let root = URL(fileURLWithPath: "/workspace")
        let configuration: ToolingJSONValue = .object(["fixture": .integer(7)])
        let session = LanguageServerRuntimeSession(
            providerID: "fixture", executableURL: URL(fileURLWithPath: "/unused"), arguments: [], environment: [:],
            prepareProcess: { _ in
                preparing.open()
                guard await resume.waitUntilOpen() else { throw CancellationError() }
                return PreparedLanguageServerProcess(executableURL: URL(fileURLWithPath: "/host/bin/server"),
                    environment: [:], launch: .init(arguments: ["--remote"], initializationOptions: nil,
                        workspaceConfiguration: configuration), core: core, release: { released.open() })
            }, core: core, pluginID: "dev.example.fixture"
        )
        defer { resume.open(); session.stop() }
        try session.start(rootURL: root, workspaceFingerprint: nil)
        try #require(await preparing.waitUntilOpen())
        let changes = [LanguageServerWorkspaceFileChange(fileURL: root.appendingPathComponent("new.swift"), kind: .created)]
        try session.notifyWorkspaceFilesChanged(changes)
        try session.synchronize(fileURL: root.appendingPathComponent("open.swift"), text: "latest", languageID: "swift")
        resume.open()
        try #require(await core.synchronized.waitUntilOpen())
        #expect(core.workspaceConfigurations == [configuration])
        #expect(core.workspaceChanges == changes)
        #expect(core.startCalls.last?.arguments == ["--remote"])
        session.stop()
        #expect(await released.waitUntilOpen())
    }

    @Test
    func stoppedPreparationReleasesLatePackageWithoutLaunching() async throws {
        let core = ScriptedProviderCore()
        let preparing = TestGate()
        let resume = TestGate()
        let released = TestGate()
        // Model a host allocation whose reply arrives after cancellation.
        let lateReply = Task { @MainActor in await resume.waitUntilOpen() }
        let session = LanguageServerRuntimeSession(
            providerID: "fixture", executableURL: URL(fileURLWithPath: "/unused"), arguments: [], environment: [:],
            prepareProcess: { _ in
                preparing.open()
                guard await lateReply.value else { throw CancellationError() }
                return PreparedLanguageServerProcess(executableURL: URL(fileURLWithPath: "/host/bin/server"),
                    environment: [:], launch: .init(arguments: [], initializationOptions: nil),
                    core: core, release: { released.open() })
            }, core: core
        )
        defer { resume.open(); lateReply.cancel(); session.stop() }
        try session.start(rootURL: URL(fileURLWithPath: "/workspace"), workspaceFingerprint: nil)
        try #require(await preparing.waitUntilOpen())
        session.stop()
        resume.open()
        #expect(await released.waitUntilOpen())
        #expect(core.startCalls.isEmpty)
        #expect(!session.isRunning)
    }

    @Test
    func failedPreparedProcessReleasesItsPackage() async throws {
        let core = ScriptedProviderCore(failStart: true)
        let released = TestGate()
        let session = LanguageServerRuntimeSession(
            providerID: "fixture", executableURL: URL(fileURLWithPath: "/unused"), arguments: [], environment: [:],
            prepareProcess: { _ in
                PreparedLanguageServerProcess(executableURL: URL(fileURLWithPath: "/host/bin/server"),
                    environment: [:], launch: .init(arguments: [], initializationOptions: nil),
                    core: core, release: { released.open() })
            }, core: core
        )
        defer { session.stop() }
        try session.start(rootURL: URL(fileURLWithPath: "/workspace"), workspaceFingerprint: nil)
        #expect(await released.waitUntilOpen())
        #expect(!session.isRunning)
    }

    @Test
    func remoteStartupReturnsBeforeTheHostRepliesAndFlushesLatestDocuments() async throws {
        let core = ScriptedProviderCore(backgroundStart: true)
        let session = LanguageServerRuntimeSession(
            providerID: "fixture", executableURL: URL(fileURLWithPath: "/host/bin/server"),
            arguments: [], environment: [:], core: core
        )
        defer { core.releaseStartup.open(); session.stop() }
        let root = URL(fileURLWithPath: "/workspace")
        let file = root.appendingPathComponent("one.swift")
        let closedFile = root.appendingPathComponent("closed.swift")
        try session.start(rootURL: root, workspaceFingerprint: nil)
        try #require(await core.started.waitUntilOpen())
        #expect(session.isRunning)
        try session.synchronize(fileURL: file, text: "old", languageID: "swift")
        try session.synchronize(fileURL: file, text: "latest", languageID: "swift", changes: [])
        try session.synchronize(fileURL: closedFile, text: "closed", languageID: "swift")
        session.closeDocument(closedFile)
        #expect(core.syncedTexts.isEmpty)

        core.releaseStartup.open()
        try #require(await core.synchronized.waitUntilOpen())
        #expect(core.syncedTexts == ["latest"])
        session.stop()
        #expect(await core.destroyed.waitUntilOpen())
    }

    @Test
    func stoppingRemoteStartupDestroysItsLateSessionWithoutPublishingReady() async throws {
        let core = ScriptedProviderCore(backgroundStart: true)
        let session = LanguageServerRuntimeSession(
            providerID: "fixture", executableURL: URL(fileURLWithPath: "/host/bin/server"),
            arguments: [], environment: [:], core: core
        )
        defer { core.releaseStartup.open(); session.stop() }
        var states: [LanguageServerSessionState] = []
        var releases = 0
        let resourcesReleased = TestGate()
        session.onStateChange = { states.append($0) }
        session.onReleased = { releases += 1 }
        session.releaseResources = {
            #expect(core.destroyed.isOpen, "Package bytes must outlive the late process")
            resourcesReleased.open()
        }
        try session.start(rootURL: URL(fileURLWithPath: "/workspace"), workspaceFingerprint: nil)
        try #require(await core.started.waitUntilOpen())
        session.stop()
        #expect(!session.isRunning)
        #expect(releases == 1)
        #expect(!resourcesReleased.isOpen)
        core.releaseStartup.open()
        #expect(await core.destroyed.waitUntilOpen())
        #expect(await resourcesReleased.waitUntilOpen())
        #expect(states == [.startingProcess, .stopped])
        #expect(core.stopCalls.isEmpty)
    }

    @Test
    func releasingRemoteStartupOwnerStillDestroysTheLateSession() async throws {
        let core = ScriptedProviderCore(backgroundStart: true)
        var session: LanguageServerRuntimeSession? = LanguageServerRuntimeSession(
            providerID: "fixture", executableURL: URL(fileURLWithPath: "/host/bin/server"),
            arguments: [], environment: [:], core: core
        )
        defer { core.releaseStartup.open(); session?.stop() }
        let resourcesReleased = TestGate()
        session?.releaseResources = {
            #expect(core.destroyed.isOpen)
            resourcesReleased.open()
        }
        weak var owner = session
        try session?.start(rootURL: URL(fileURLWithPath: "/workspace"), workspaceFingerprint: nil)
        try #require(await core.started.waitUntilOpen())
        session = nil
        #expect(owner == nil)
        core.releaseStartup.open()
        #expect(await core.destroyed.waitUntilOpen())
        #expect(await resourcesReleased.waitUntilOpen())
    }

    /// Native execution and model requests share the same process; no page
    /// or plugin-function negotiation participates.
    @Test(arguments: ["lithe/build/execute", "lithe/build/test"])
    func nativeExecutionReusesTheWorkspaceProviderAndDeliversProgress(method: String) async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }
        let packageBefore = try fixture.packageSnapshot()
        _ = try await fixture.load()
        let received = BuildProgressRecorder()
        let result = try await fixture.sessions.execute(BuildProviderRequest(
            method: method, params: .object([:]), optionFingerprint: "",
            executesProjectCode: true, mayUseNetwork: true
        ), on: fixture.target, timeout: .seconds(5)) { received.values.append($0) }
        #expect(result == BuildProviderExecutionResult(exitCode: 0, output: "built"))
        #expect(received.values == [BuildProviderProgress(percentage: 50, output: "building")])
        #expect(fixture.core.startCalls.count == 1)
        #expect(fixture.core.buildRequests == ["lithe/build/model", method])
        let otherRoot = fixture.root.appendingPathComponent("other-workspace")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = BuildProviderTarget(
            pluginID: ProviderFixture.pluginID, manifest: fixture.manifest, packageURL: fixture.packageURL,
            buildSystemID: "gradle", workspaceURL: otherRoot
        )
        _ = try await fixture.sessions.execute(BuildProviderRequest(
            method: method, params: .object([:]), optionFingerprint: "",
            executesProjectCode: true, mayUseNetwork: true
        ), on: other, timeout: .seconds(5)) { _ in }
        #expect(fixture.core.startCalls.count == 2)
        #expect(try fixture.packageSnapshot() == packageBefore)
        fixture.sessions.stopProviders(ofPlugin: ProviderFixture.pluginID)
        #expect(fixture.core.stopCalls.count == 2)
    }

    @Test
    func nativeRunPreparationReusesProviderAndKeepsPackageReadOnly() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }
        let before = try fixture.packageSnapshot()
        _ = try await fixture.load()
        let progress = BuildProgressRecorder()
        let result = try await fixture.sessions.prepareRun(BuildProviderRequest(
            method: "lithe/build/prepareRun", params: .object([:]), optionFingerprint: "",
            executesProjectCode: true, mayUseNetwork: true), on: fixture.target, timeout: .seconds(5)) { progress.values.append($0) }
        #expect(result == .object(["executable": .object(["kind": .string("command"), "value": .string("java")]),
                                   "arguments": .array([]), "workingDirectory": .string("."), "environment": .object([:])]))
        #expect(progress.values == [BuildProviderProgress(percentage: 50, output: "building")])
        #expect(fixture.core.startCalls.count == 1)
        #expect(fixture.core.buildRequests == ["lithe/build/model", "lithe/build/prepareRun"])
        #expect(try fixture.packageSnapshot() == before)
    }

    /// Cancellation reaches Core for the exact workspace command, while the
    /// shared language server stays available for editing and later sessions.
    @Test(arguments: [false, true])
    func aHostedDebugStartCommandCompletesOrCancelsWithoutStoppingTheServer(cancel: Bool) async throws {
        let core = ScriptedProviderCore()
        let session = LanguageServerRuntimeSession(
            providerID: "example", executableURL: URL(fileURLWithPath: "/tools/example-ls"),
            arguments: [], environment: [:], core: core
        )
        let root = URL(fileURLWithPath: "/workspace/hosted-debug", isDirectory: true)
        try session.start(rootURL: root, workspaceFingerprint: nil)
        let finished = TestGate()
        let request = Task { @MainActor () -> Result<ToolingJSONValue, Error> in
            defer { finished.open() }
            do {
                return .success(try await session.executeReturningValue(
                    .init(title: "Start", command: "example.startDebugSession", arguments: []), fileURL: root
                ))
            } catch { return .failure(error) }
        }
        defer { request.cancel(); session.stop() }
        try #require(await core.commandStarted.waitUntilOpen(), "The workspace command never started")
        if cancel {
            request.cancel()
            try #require(await core.functionCancelled.waitUntilOpen(), "Core never received command cancellation")
        } else {
            core.finishDebugStartCommand()
        }
        try #require(await finished.waitUntilOpen(), "The command did not finish before its local deadline")
        switch await request.value {
        case .success(let value):
            #expect(!cancel)
            #expect(value == .integer(4711))
        case .failure(let error):
            #expect(cancel)
            #expect(error is CancellationError)
        }
        #expect(session.isRunning)
        #expect(core.stopCalls.isEmpty)
        // A response already in flight cannot resurrect a cancelled command.
        if cancel { core.finishDebugStartCommand() }
        session.stop()
        try #require(await core.destroyed.waitUntilOpen(), "The language session did not release its resources")
    }

    /// A second request reuses the process; stopping the plugin's providers,
    /// which the plugin manager does before replacing its package, ends it
    /// and the next request starts a new one.
    @Test
    func packageReplacementStopsTheProviderAndTheNextRequestStartsAgain() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }

        _ = try await fixture.load()
        _ = try await fixture.load()
        #expect(fixture.core.startCalls.count == 1)
        #expect(fixture.core.buildRequests == ["lithe/build/model", "lithe/build/model"])

        fixture.sessions.stopProviders(ofPlugin: "dev.example.other")
        #expect(fixture.core.stopCalls.isEmpty)
        fixture.sessions.stopProviders(ofPlugin: ProviderFixture.pluginID)
        #expect(fixture.core.stopCalls.count == 1)

        _ = try await fixture.load()
        #expect(fixture.core.startCalls.count == 2)
    }

    /// The host's `refresh` and `tool` hints are part of the params Core
    /// planned; the session forwards them to the process unchanged.
    @Test
    func providerHintsReachTheProcessUnchanged() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }
        let params: ToolingJSONValue = .object([
            "buildSystemID": .string("gradle"),
            "root": .string("."),
            "refresh": .bool(true),
            "tool": .object(["executable": .string("/opt/tools/gradle/bin/gradle")]),
        ])

        _ = try await fixture.load(params: params)

        #expect(fixture.core.buildParams == [params])
    }

    /// Launch arguments come from the plugin's settings, so a changed value
    /// replaces the running process instead of reusing its old arguments.
    @Test
    func changedSettingRestartsTheProviderWithTheNewArguments() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }

        _ = try await fixture.load()
        #expect(fixture.core.startCalls.last?.arguments == ["--heap", "1024"])

        fixture.settings.setValue(.integer(4096), forSetting: "providerHeapMB", plugin: ProviderFixture.pluginID)
        _ = try await fixture.load()

        #expect(fixture.core.stopCalls.count == 1)
        #expect(fixture.core.startCalls.count == 2)
        #expect(fixture.core.startCalls.last?.arguments == ["--heap", "4096"])

        _ = try await fixture.load()
        #expect(fixture.core.startCalls.count == 2)
    }

    /// Shutdown rejects a queued initialize reply and releases the runtime
    /// after the terminal event, for ready and initializing providers alike.
    @Test(arguments: [false, true])
    func releasingProvidersStopsReadyAndInitializingSessions(initializing: Bool) async throws {
        let core = ScriptedProviderCore(
            initialState: initializing ? "initializing" : "ready",
            readyAfterStop: initializing
        )
        let fixture = try ProviderFixture(core: core)
        let finished = TestGate()
        let request = Task { @MainActor () -> Result<ToolingJSONValue, Error> in
            defer { finished.open() }
            do {
                return .success(try await fixture.load())
            } catch {
                return .failure(error)
            }
        }
        defer {
            request.cancel()
            fixture.remove()
            core.finishStopping()
        }
        try #require(await core.started.waitUntilOpen())
        if !initializing { try #require(await finished.waitUntilOpen()) }

        fixture.sessions.retainProviders { _ in false }

        #expect(core.stopCalls == ["provider-1"])
        let requestFinished = await finished.waitUntilOpen()
        #expect(requestFinished)
        if requestFinished {
            switch await request.value {
            case .success(let reply):
                #expect(!initializing)
                #expect(reply == .object(["session": .string("provider-1")]))
            case .failure(let error):
                #expect(initializing)
                #expect(error is CancellationError)
            }
            #expect(core.buildRequests == (initializing ? [] : ["lithe/build/model"]))
        }
        core.finishStopping()
        #expect(await core.destroyed.waitUntilOpen())
        fixture.sessions.retainProviders { _ in false }
        #expect(core.stopCalls == ["provider-1"])
    }

    /// A packaged entry that lost its executable bit is refused before any
    /// process starts, with the path in the message.
    @Test
    func packagedProviderThatIsNotExecutableNeverStarts() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.executableURL.path)

        await #expect(throws: MacPluginLanguageServerLaunchResolver.ResolutionError.packagedExecutableNotRunnable(
            ProviderFixture.executablePath
        )) {
            _ = try await fixture.load()
        }
        #expect(fixture.core.startCalls.isEmpty)
    }

    /// The provider starts as the plugin's own session, so Core negotiates its
    /// functions; results, progress and plugin-defined failure codes come back
    /// to the caller unchanged, and a Core refusal keeps its function code.
    @Test
    func pluginFunctionsRunOnThePluginsOwnProviderWithProgressAndFailures() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }

        #expect(try await fixture.sessions.pluginFunctions(of: fixture.target) == ["snapshot.read", "workspace.build"])
        #expect(fixture.core.startCalls.map(\.pluginID) == [ProviderFixture.pluginID])

        let reports = ProgressReports()
        let value = try await fixture.invoke("workspace.build") { reports.items.append($0) }
        #expect(value == .object(["built": .bool(true)]))
        #expect(reports.items == [PluginFunctionProgress(message: "Compiling", percentage: 50)])
        #expect(fixture.core.functionRequests == [
            ScriptedProviderCore.FunctionCall(pluginID: ProviderFixture.pluginID, functionID: "workspace.build")
        ])

        await #expect(throws: PluginFunctionFailure(
            code: "plugin.function.failed", message: "No snapshot yet.", pluginErrorCode: "snapshot.missing"
        )) {
            _ = try await fixture.invoke("snapshot.read")
        }
        await #expect(throws: PluginFunctionFailure(code: "plugin.function.unknown", message: "Unknown function.")) {
            _ = try await fixture.invoke("missing.function")
        }
        #expect(fixture.core.startCalls.count == 1)
    }

    /// Cancelling the caller cancels the Core operation, and stopping the
    /// plugin's providers ends the process that served the function.
    @Test
    func cancellingAFunctionCancelsTheCoreOperation() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }

        let call = Task { @MainActor in try await fixture.invoke("workspace.wait") }
        try #require(await fixture.core.functionStarted.waitUntilOpen())
        call.cancel()
        try #require(await fixture.core.functionCancelled.waitUntilOpen())
        await #expect(throws: CancellationError.self) { _ = try await call.value }

        fixture.sessions.stopProviders(ofPlugin: ProviderFixture.pluginID)
        #expect(fixture.core.stopCalls.count == 1)
    }

    /// A failed write carries an OS error text in `details`; only Core's
    /// refusal codes become the caller's code, so this one keeps its own
    /// and the text stays in the message.
    @Test
    func aTransportFailureKeepsItsCodeAndNotTheOSErrorText() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }

        await #expect(throws: PluginFunctionFailure(
            code: "processFailed", message: "Could not write to language-server stdin.: Broken pipe (os error 32)"
        )) {
            _ = try await fixture.invoke("transport.broken")
        }
    }

    /// Core writes a request to the backend's stdin synchronously. A write
    /// blocked on a backend that stopped reading never holds the main actor,
    /// and once the call is cancelled the backend is ended to free it.
    @Test
    func aBlockedSendNeverHoldsTheMainActorAndCancelEndsTheBackend() async throws {
        let fixture = try ProviderFixture()
        defer {
            fixture.core.releaseStuckSend()
            fixture.remove()
        }
        let ended = TestGate()
        fixture.endedBackends.onEnd = { immediately in
            guard immediately else { return }
            ended.open()
            fixture.core.releaseStuckSend()
        }
        _ = try await fixture.sessions.pluginFunctions(of: fixture.target)
        let finished = TestGate()
        let call = Task { @MainActor in
            defer { finished.open() }
            return try await fixture.invoke("workspace.stuck")
        }
        // This test runs on the main actor: it resumes here only because the
        // blocked write runs elsewhere.
        try #require(await fixture.core.stuckSendStarted.waitUntilOpen())
        #expect(fixture.endedBackends.calls.isEmpty)

        call.cancel()
        try #require(await ended.waitUntilOpen())
        try #require(await finished.waitUntilOpen())
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        let token = try #require(fixture.core.startCalls.first?.environment["LITHE_PLUGIN_BACKEND_SCOPE"])
        #expect(fixture.endedBackends.calls == [.init(token: token, immediately: true)])
    }

    /// Core's event drain waits on the session lock while the server's reader
    /// applies a message, so it runs off the main actor. A request sent while a
    /// drain is out waits for it, so that drain cannot return the request's
    /// reply before the operation is registered.
    @Test
    func aHeldEventDrainNeitherBlocksTheMainActorNorOvertakesARequest() async throws {
        let fixture = try ProviderFixture()
        defer {
            fixture.core.releaseHeldPoll()
            fixture.remove()
        }
        _ = try await fixture.sessions.pluginFunctions(of: fixture.target)
        fixture.core.holdNextPoll()
        // This test runs on the main actor: it resumes here only because the
        // held drain runs elsewhere.
        try #require(await fixture.core.pollHeld.waitUntilOpen())

        // The call runs on the main actor up to its wait for the drain; the
        // release is queued behind it.
        let call = Task { @MainActor in try await fixture.invoke("workspace.build") }
        let release = Task { @MainActor in fixture.core.releaseHeldPoll() }
        await release.value
        #expect(try await call.value == .object(["built": .bool(true)]))
        #expect(fixture.core.requestsWhilePollHeld == 0)
    }

    /// Stopping a provider whose write is blocked does not wait on it: Core's
    /// stop runs off the main actor and the backend is ended after the grace.
    @Test
    func stoppingAProviderWithABlockedSendEndsTheBackend() async throws {
        let fixture = try ProviderFixture()
        defer {
            fixture.core.releaseStuckSend()
            fixture.remove()
        }
        let ended = TestGate()
        fixture.endedBackends.onEnd = { immediately in
            guard immediately else { return }
            ended.open()
            fixture.core.releaseStuckSend()
        }
        _ = try await fixture.sessions.pluginFunctions(of: fixture.target)
        let finished = TestGate()
        let call = Task { @MainActor in
            defer { finished.open() }
            return try await fixture.invoke("workspace.stuck")
        }
        try #require(await fixture.core.stuckSendStarted.waitUntilOpen())

        fixture.sessions.stopProviders(ofPlugin: ProviderFixture.pluginID)
        try #require(await ended.waitUntilOpen())
        try #require(await finished.waitUntilOpen())
        await #expect(throws: PluginFunctionFailure.self) { _ = try await call.value }
        // Release follows the terminal event Core's stop queued.
        try #require(await fixture.core.destroyed.waitUntilOpen())
        #expect(fixture.core.stopCalls == ["provider-1"])
    }

    /// The start is shared by every call that arrives meanwhile. Cancelling
    /// one caller ends its wait at once, while the start goes on and serves
    /// the next call.
    @Test
    func cancellingACallWhileTheProviderStartsEndsOnlyThatCall() async throws {
        let core = ScriptedProviderCore(initialState: "initializing")
        let fixture = try ProviderFixture(core: core)
        defer { fixture.remove() }
        let finished = TestGate()
        let first = Task { @MainActor in
            defer { finished.open() }
            return try await fixture.invoke("workspace.build")
        }
        try #require(await core.started.waitUntilOpen())

        first.cancel()
        try #require(await finished.waitUntilOpen())
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(core.functionRequests.isEmpty)

        core.becomeReady()
        #expect(try await fixture.invoke("workspace.build") == .object(["built": .bool(true)]))
        #expect(core.startCalls.count == 1)
    }

    /// Every backend starts with its own token, and once its session has
    /// ended the host ends what carries that token, gracefully.
    @Test
    func anEndedBackendHasWhatItLeftEnded() async throws {
        let fixture = try ProviderFixture()
        defer { fixture.remove() }
        let released = TestGate()
        fixture.endedBackends.onEnd = { immediately in
            if !immediately { released.open() }
        }
        _ = try await fixture.sessions.pluginFunctions(of: fixture.target)
        let token = try #require(fixture.core.startCalls.first?.environment["LITHE_PLUGIN_BACKEND_SCOPE"])
        #expect(!token.isEmpty)

        fixture.sessions.stopProviders(ofPlugin: ProviderFixture.pluginID)
        try #require(await released.waitUntilOpen())
        #expect(fixture.endedBackends.calls == [.init(token: token, immediately: false)])
    }
}

/// What the host asked to end, by backend token.
@MainActor
private final class EndedBackends {
    struct Call: Equatable { let token: String; let immediately: Bool }
    var calls: [Call] = []
    var onEnd: ((_ immediately: Bool) -> Void)?
}

@MainActor
private final class ProgressReports {
    var items: [PluginFunctionProgress] = []
}

/// A Gradle-like plugin whose provider is a packaged executable with a
/// setting in its arguments.
@MainActor
private struct ProviderFixture {
    static let pluginID = "dev.lithe.fixture.build-provider"
    static let executablePath = "provider/bin/provider"

    let root: URL
    let packageURL: URL
    let workspaceURL: URL
    let manifest: Data
    let settings = InMemoryPluginSettings()
    let core: ScriptedProviderCore
    let sessions: MacBuildProviderSessions
    let endedBackends = EndedBackends()

    var executableURL: URL { packageURL.appendingPathComponent(Self.executablePath) }

    init(core: ScriptedProviderCore = ScriptedProviderCore()) throws {
        self.core = core
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-build-provider-\(UUID().uuidString)", isDirectory: true)
        packageURL = root.appendingPathComponent("package", isDirectory: true)
        workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let fixtureURL = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-provider.plugin.json")
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var buildSystems = try #require(object["buildSystems"] as? [[String: Any]])
        buildSystems[0]["provider"] = [
            "launch": ["kind": "packaged", "path": Self.executablePath],
            "arguments": ["--heap", "${setting:providerHeapMB}"],
            "executesProjectCode": true,
            "mayUseNetwork": true
        ] as [String: Any]
        object["buildSystems"] = buildSystems
        _ = try DeclarativePluginTestSupport.writePackage(at: packageURL, manifest: object)
        let executable = packageURL.appendingPathComponent(Self.executablePath)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        manifest = try DeclarativePluginTestSupport.operations
            .validate(manifest: Data(contentsOf: packageURL.appendingPathComponent("plugin.json")))
            .normalizedManifest

        let operations = DeclarativePluginTestSupport.operations
        sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(
                planner: operations,
                directories: MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true)),
                settings: settings
            ),
            tools: UnusedBuildTools(),
            versionChecker: operations,
            runtime: EmptyToolRuntime(),
            core: core,
            processRegistry: nil,
            stuckSendGrace: .milliseconds(20),
            endBackendProcesses: { [endedBackends] token, immediately in
                endedBackends.calls.append(.init(token: token, immediately: immediately))
                endedBackends.onEnd?(immediately)
            }
        )
    }

    var target: BuildProviderTarget {
        BuildProviderTarget(
            pluginID: Self.pluginID, manifest: manifest, packageURL: packageURL,
            buildSystemID: "gradle", workspaceURL: workspaceURL
        )
    }

    func invoke(
        _ functionID: String,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void = { _ in }
    ) async throws -> ToolingJSONValue {
        try await sessions.invokePluginFunction(
            functionID, params: .object([:]), on: target, timeout: .seconds(5), progress: progress
        )
    }

    func load(params: ToolingJSONValue = .object([:])) async throws -> ToolingJSONValue {
        try await sessions.send(
            BuildProviderRequest(
                method: "lithe/build/model", params: params, optionFingerprint: "",
                executesProjectCode: true, mayUseNetwork: true
            ),
            to: BuildProviderTarget(
                pluginID: Self.pluginID, manifest: manifest, packageURL: packageURL,
                buildSystemID: "gradle", workspaceURL: workspaceURL
            ),
            timeout: .seconds(5)
        )
    }

    /// Compare both the complete listing and bytes, including added empty
    /// directories; runtime state must not appear next to packaged inputs.
    func packageSnapshot() throws -> [String: Data] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let files = try #require(FileManager.default.enumerator(
            at: packageURL, includingPropertiesForKeys: Array(keys)
        ))
        var snapshot: [String: Data] = [:]
        for case let url as URL in files {
            let relative = String(url.path.dropFirst(packageURL.path.count))
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                snapshot["link:" + relative] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            } else if values.isDirectory == true {
                snapshot["directory:" + relative] = Data()
            } else {
                snapshot["file:" + relative] = try Data(contentsOf: url)
            }
        }
        return snapshot
    }

    func remove() {
        sessions.retainProviders { _ in false }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Answers requests immediately and exposes gates for lifecycle ordering.
private final class ScriptedProviderCore: LanguageServerRuntimeCore, @unchecked Sendable {
    struct StartCall { let arguments: [String]; let pluginID: String?; var environment: [String: String] = [:] }
    struct FunctionCall: Equatable { let pluginID: String; let functionID: String }

    let started = TestGate()
    let functionStarted = TestGate()
    let functionCancelled = TestGate()
    let commandStarted = TestGate()
    let destroyed = TestGate()
    let releaseStartup = TestGate()
    let synchronized = TestGate()
    /// Opened when a `workspace.stuck` send is blocked; it stays blocked, as
    /// a write to a backend that stopped reading would, until `releaseStuckSend`.
    let stuckSendStarted = TestGate()
    private let stuckSendReleased = TestGate()
    /// Opened when a poll armed by `holdNextPoll()` is blocked; it stays
    /// blocked, as Core's drain does behind a busy session lock, until
    /// `releaseHeldPoll()`.
    let pollHeld = TestGate()
    private let heldPollReleased = TestGate()
    private var _holdNextPoll = false
    private var _pollIsHeld = false
    private var _requestsWhilePollHeld = 0
    private let initialState: String
    private let readyAfterStop: Bool
    private let backgroundStart: Bool
    private let failStart: Bool
    private let lock = NSLock()
    private var nextSession = 0
    private var events: [String: [LanguageServerRuntimeEvent]] = [:]
    private var _startCalls: [StartCall] = []
    private var _stopCalls: [String] = []
    private var _cancelledOperations: [String] = []
    private var _buildRequests: [String] = []
    private var _buildParams: [ToolingJSONValue] = []
    private var _functionRequests: [FunctionCall] = []
    private var _syncedTexts: [String] = []
    private var _savedTexts: [String] = []
    private var _saveFails = false
    var savedTexts: [String] { lock.withLock { _savedTexts } }
    var saveFails: Bool {
        get { lock.withLock { _saveFails } }
        set { lock.withLock { _saveFails = newValue } }
    }
    private var _workspaceConfigurations: [ToolingJSONValue?] = []
    private var _workspaceChanges: [LanguageServerWorkspaceFileChange] = []

    init(initialState: String = "ready", readyAfterStop: Bool = false, backgroundStart: Bool = false, failStart: Bool = false) {
        self.initialState = initialState
        self.readyAfterStop = readyAfterStop
        self.backgroundStart = backgroundStart
        self.failStart = failStart
    }

    func requiresBackgroundLanguageServerStart(rootURL _: URL) -> Bool { backgroundStart }
    var syncedTexts: [String] { lock.withLock { _syncedTexts } }
    var workspaceConfigurations: [ToolingJSONValue?] { lock.withLock { _workspaceConfigurations } }
    var workspaceChanges: [LanguageServerWorkspaceFileChange] { lock.withLock { _workspaceChanges } }

    func notifyLanguageServerWorkspaceFilesChanged(sessionID _: String, changes: [LanguageServerWorkspaceFileChange]) -> Result<Void, LanguageServerRuntimeFailure> {
        lock.withLock { _workspaceChanges.append(contentsOf: changes) }
        return .success(())
    }
    var startCalls: [StartCall] { lock.withLock { _startCalls } }
    var stopCalls: [String] { lock.withLock { _stopCalls } }
    var cancelledOperations: [String] { lock.withLock { _cancelledOperations } }
    var buildRequests: [String] { lock.withLock { _buildRequests } }
    var buildParams: [ToolingJSONValue] { lock.withLock { _buildParams } }
    var functionRequests: [FunctionCall] { lock.withLock { _functionRequests } }

    func startLanguageServer(
        providerID: String, executableURL: URL, arguments: [String], environment: [String: String],
        rootURL: URL, workingDirectoryURL: URL, initializationOptions: ToolingJSONValue?,
        runtimeExecutableURL: URL?, jdtlsLaunchResources: JDTLSLaunchResources?, cacheDirectoryURL: URL?,
        workspaceFingerprint: String?, initializeTimeout: TimeInterval, requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        startLanguageServer(
            providerID: providerID, executableURL: executableURL, arguments: arguments,
            environment: environment, rootURL: rootURL, workingDirectoryURL: workingDirectoryURL,
            initializationOptions: initializationOptions, runtimeExecutableURL: runtimeExecutableURL,
            jdtlsLaunchResources: jdtlsLaunchResources, cacheDirectoryURL: cacheDirectoryURL,
            workspaceFingerprint: workspaceFingerprint, mavenContext: nil, initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    func startLanguageServer(
        providerID _: String, executableURL _: URL, arguments: [String], environment _: [String: String],
        rootURL _: URL, workingDirectoryURL _: URL, initializationOptions _: ToolingJSONValue?,
        runtimeExecutableURL _: URL?, jdtlsLaunchResources _: JDTLSLaunchResources?, cacheDirectoryURL _: URL?,
        workspaceFingerprint _: String?, mavenContext _: MavenLaunchContext?, initializeTimeout _: TimeInterval,
        requestTimeout _: TimeInterval, shutdownTimeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        if failStart { return .failure(.init(code: "processFailed", message: "fixture startup failed")) }
        if backgroundStart {
            started.open()
            guard releaseStartup.waitSynchronously() else {
                return .failure(.init(code: "timed_out", message: "The test did not release startup."))
            }
        }
        let result = lock.withLock {
            nextSession += 1
            _startCalls.append(StartCall(arguments: arguments, pluginID: nil))
            return LanguageServerRuntimeStart(
                sessionID: "provider-\(nextSession)", state: initialState, processID: nil
            )
        }
        started.open()
        return .success(result)
    }

    /// Core queues the negotiated functions before the session turns ready.
    /// With `initialState: "initializing"` the session stays initializing
    /// until `becomeReady()`, or until a stop queues the late ready reply.
    func startPluginLanguageServer(
        pluginID: String, providerID: String, executableURL: URL, arguments: [String],
        environment: [String: String], rootURL: URL, initializationOptions: ToolingJSONValue?,
        workspaceConfiguration: ToolingJSONValue?, hostServices: [String],
        hostIntegrationLaunch _: LanguageServerHostIntegrationLaunch?, cacheDirectoryURL _: URL?,
        workspaceFingerprint _: String?, mavenContext _: MavenLaunchContext?,
        javaGradle _: JavaGradleImportConfiguration?, initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval, shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lock.withLock { _workspaceConfigurations.append(workspaceConfiguration) }
        // The host-services overload keeps the protocol's default refusal of services.
        return startPluginLanguageServer(pluginID: pluginID, providerID: providerID, executableURL: executableURL,
            arguments: arguments, environment: environment, rootURL: rootURL, initializationOptions: initializationOptions,
            hostServices: hostServices, initializeTimeout: initializeTimeout, requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout)
    }

    func startPluginLanguageServer(
        pluginID: String, providerID _: String, executableURL _: URL, arguments: [String],
        environment: [String: String], rootURL _: URL, initializationOptions _: ToolingJSONValue?,
        initializeTimeout _: TimeInterval, requestTimeout _: TimeInterval, shutdownTimeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        let result = lock.withLock {
            nextSession += 1
            _startCalls.append(StartCall(arguments: arguments, pluginID: pluginID, environment: environment))
            let sessionID = "provider-\(nextSession)"
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(
                type: "functionsChanged",
                result: .object([
                    "functions": .array([.string("workspace.build"), .string("snapshot.read")]),
                    "removed": .array([])
                ])
            ))
            if initialState == "ready" {
                events[sessionID, default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "ready"))
            }
            return LanguageServerRuntimeStart(sessionID: sessionID, state: "initializing", processID: nil)
        }
        started.open()
        return .success(result)
    }

    func becomeReady() {
        lock.withLock {
            let sessionID = "provider-\(nextSession)"
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "ready"))
        }
    }

    /// Lets the blocked send fail the way a write to a killed process does.
    func releaseStuckSend() { stuckSendReleased.open() }

    func holdNextPoll() { lock.withLock { _holdNextPoll = true } }
    func releaseHeldPoll() { heldPollReleased.open() }
    /// Function requests that reached Core while a held poll was out.
    var requestsWhilePollHeld: Int { lock.withLock { _requestsWhilePollHeld } }

    /// `workspace.build` reports progress then succeeds, `snapshot.read`
    /// fails with a plugin code, `workspace.wait` runs until cancelled,
    /// `workspace.stuck` blocks like a write to a backend that stopped
    /// reading and then fails with an OS error text, `transport.broken`
    /// fails that way at once, and anything else is refused like Core
    /// refuses an unknown function.
    func requestPluginFunction(
        sessionID: String, pluginID: String, functionID: String, params _: ToolingJSONValue, timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        let brokenPipe = LanguageServerRuntimeFailure(
            code: "processFailed", message: "Could not write to language-server stdin.",
            details: "Broken pipe (os error 32)"
        )
        if functionID == "workspace.stuck" {
            stuckSendStarted.open()
            _ = stuckSendReleased.waitSynchronously(timeout: 10)
            return .failure(brokenPipe)
        }
        if functionID == "transport.broken" { return .failure(brokenPipe) }
        let known = ["workspace.build", "snapshot.read", "workspace.wait"]
        guard known.contains(functionID) else {
            return .failure(LanguageServerRuntimeFailure(
                code: "invalidRequest", message: "Unknown function.", details: "plugin.function.unknown"
            ))
        }
        let operation = lock.withLock {
            if _pollIsHeld { _requestsWhilePollHeld += 1 }
            _functionRequests.append(FunctionCall(pluginID: pluginID, functionID: functionID))
            let operationID = "\(sessionID)-fn-\(_functionRequests.count)"
            switch functionID {
            case "workspace.build":
                events[sessionID, default: []] += [
                    LanguageServerRuntimeEvent(
                        type: "requestProgress", operationID: operationID,
                        result: .object(["message": .string("Compiling"), "percentage": .integer(50)])
                    ),
                    LanguageServerRuntimeEvent(
                        type: "requestCompleted", operationID: operationID,
                        result: .object(["value": .object(["built": .bool(true)])])
                    )
                ]
            case "snapshot.read":
                events[sessionID, default: []].append(LanguageServerRuntimeEvent(
                    type: "requestCompleted", operationID: operationID,
                    error: LanguageServerRuntimeError(
                        code: "plugin.function.failed", stage: "request", message: "No snapshot yet.",
                        underlyingMessage: nil, processExitCode: nil, pluginErrorCode: "snapshot.missing"
                    )
                ))
            default:
                break
            }
            return LanguageServerRuntimeOperation(operationID: operationID)
        }
        if functionID == "workspace.wait" { functionStarted.open() }
        return .success(operation)
    }

    func stopLanguageServer(sessionID: String) {
        lock.withLock {
            _stopCalls.append(sessionID)
            // The test withholds the terminal event until the waiter has
            // handled this initialize reply that was queued before shutdown.
            let state = readyAfterStop ? "ready" : "stopped"
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: state))
        }
    }

    func finishStopping() {
        lock.withLock {
            for sessionID in _stopCalls {
                events[sessionID, default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "stopped"))
            }
        }
    }

    func requestBuildProvider(
        sessionID: String, method: String, params: ToolingJSONValue, timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lock.withLock {
            _buildRequests.append(method)
            _buildParams.append(params)
            let operationID = "\(sessionID)-\(_buildRequests.count)"
            if ["lithe/build/execute", "lithe/build/test", "lithe/build/prepareRun"].contains(method) {
                events[sessionID, default: []].append(LanguageServerRuntimeEvent(
                    type: "requestProgress", operationID: operationID,
                    result: .object(["percentage": .integer(50), "output": .string("building")])
                ))
            }
            let launch: ToolingJSONValue = .object(["executable": .object(["kind": .string("command"), "value": .string("java")]),
                                                   "arguments": .array([]), "workingDirectory": .string("."), "environment": .object([:])])
            let value: ToolingJSONValue = method == "lithe/build/prepareRun" ? launch : ["lithe/build/execute", "lithe/build/test"].contains(method)
                ? .object(["exitCode": .integer(0), "output": .string("built")])
                : .object(["session": .string(sessionID)])
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(
                type: "requestCompleted", operationID: operationID,
                result: .object(["value": value])
            ))
            return .success(LanguageServerRuntimeOperation(operationID: operationID))
        }
    }

    func pollLanguageServerEvents(sessionID: String) -> [LanguageServerRuntimeEvent] {
        let hold = lock.withLock {
            defer { _holdNextPoll = false }
            _pollIsHeld = _holdNextPoll
            return _holdNextPoll
        }
        if hold {
            pollHeld.open()
            _ = heldPollReleased.waitSynchronously(timeout: 5)
            lock.withLock { _pollIsHeld = false }
        }
        return lock.withLock { events.removeValue(forKey: sessionID) ?? [] }
    }

    func syncLanguageServerDocument(
        sessionID _: String, fileURL _: URL, languageID _: String, text: String
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure> {
        lock.withLock { _syncedTexts.append(text) }
        synchronized.open()
        return .success(LanguageServerDocumentSync(documentVersion: 1, changed: false))
    }

    func closeLanguageServerDocument(sessionID _: String, fileURL _: URL) {}

    func saveLanguageServerDocument(sessionID _: String, fileURL _: URL, text: String)
        -> Result<Bool, LanguageServerRuntimeFailure> {
        lock.withLock {
            _savedTexts.append(text)
            return _saveFails ? .failure(LanguageServerRuntimeFailure(
                code: "processFailed", message: "Save transport failed.", details: nil)) : .success(true)
        }
    }

    func requestLanguageServerOperation(
        sessionID _: String, operation: LanguageServerOperation, fileURL _: URL?, virtualURI _: String?,
        position _: LanguageServerPosition?, newName _: String?, range _: LanguageServerRange?,
        diagnostics _: [LanguageServerDiagnostic], completionContext: LanguageServerCompletionContext?, completionItem _: LanguageServerCompletionItem?,
        codeAction _: LanguageServerCodeAction?, command: LanguageServerCommand?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        if operation == .executeCommand, command?.command == "example.startDebugSession" {
            commandStarted.open()
            return .success(LanguageServerRuntimeOperation(operationID: "debug-start"))
        }
        return .success(LanguageServerRuntimeOperation(operationID: "unused"))
    }

    func finishDebugStartCommand() {
        lock.withLock {
            events["provider-\(nextSession)", default: []].append(LanguageServerRuntimeEvent(
                type: "requestCompleted", operationID: "debug-start",
                result: .object(["value": .integer(4711)])
            ))
        }
    }

    func prepareJavaLaunch(
        sessionID _: String, fileURL _: URL, mainClass _: String?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        commandStarted.open()
        return .success(LanguageServerRuntimeOperation(operationID: "java-launch"))
    }

    func finishJavaLaunch(_ result: ToolingJSONValue) {
        lock.withLock {
            events["provider-\(nextSession)", default: []].append(LanguageServerRuntimeEvent(
                type: "requestCompleted", operationID: "java-launch", result: result
            ))
        }
    }

    func cancelLanguageServerOperation(sessionID: String, operationID: String) {
        lock.withLock {
            _cancelledOperations.append(operationID)
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(
                type: "requestCompleted", operationID: operationID,
                error: LanguageServerRuntimeError(
                    code: "requestCancelled", stage: "request", message: "Cancelled.",
                    underlyingMessage: nil, processExitCode: nil
                )
            ))
        }
        functionCancelled.open()
    }
    func destroyLanguageServer(sessionID _: String) { destroyed.open() }
}

/// The packaged provider never goes through tool discovery.
private final class UnusedBuildTools: BuildToolResolving {
    struct Unexpected: Error {}

    func resolve(
        _: BuildInvocation, displayName _: String, workspaceURL _: URL,
        checkVersion _: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        throw Unexpected()
    }
}

private final class EmptyToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools _: [String]) -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}

@MainActor
private final class BuildProgressRecorder { var values: [BuildProviderProgress] = [] }
