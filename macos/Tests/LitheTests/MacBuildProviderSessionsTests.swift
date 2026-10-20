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
    static let pluginID = "dev.lithe.fixture.gradle-provider"
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
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/gradle-provider.plugin.json")
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

    func load() async throws -> ToolingJSONValue {
        try await sessions.send(
            BuildProviderRequest(
                method: "lithe/build/model", params: .object([:]), optionFingerprint: "",
                executesProjectCode: true, mayUseNetwork: true
            ),
            to: BuildProviderTarget(
                pluginID: Self.pluginID, manifest: manifest, packageURL: packageURL,
                buildSystemID: "gradle", workspaceURL: workspaceURL
            ),
            timeout: .seconds(5)
        )
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
    let destroyed = TestGate()
    /// Opened when a `workspace.stuck` send is blocked; it stays blocked, as
    /// a write to a backend that stopped reading would, until `releaseStuckSend`.
    let stuckSendStarted = TestGate()
    private let stuckSendReleased = TestGate()
    private let initialState: String
    private let readyAfterStop: Bool
    private let lock = NSLock()
    private var nextSession = 0
    private var events: [String: [LanguageServerRuntimeEvent]] = [:]
    private var _startCalls: [StartCall] = []
    private var _stopCalls: [String] = []
    private var _buildRequests: [String] = []
    private var _functionRequests: [FunctionCall] = []

    init(initialState: String = "ready", readyAfterStop: Bool = false) {
        self.initialState = initialState
        self.readyAfterStop = readyAfterStop
    }

    var startCalls: [StartCall] { lock.withLock { _startCalls } }
    var stopCalls: [String] { lock.withLock { _stopCalls } }
    var buildRequests: [String] { lock.withLock { _buildRequests } }
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
        sessionID: String, method: String, params _: ToolingJSONValue, timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lock.withLock {
            _buildRequests.append(method)
            let operationID = "\(sessionID)-\(_buildRequests.count)"
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(
                type: "requestCompleted",
                operationID: operationID,
                result: .object(["value": .object(["session": .string(sessionID)])])
            ))
            return .success(LanguageServerRuntimeOperation(operationID: operationID))
        }
    }

    func pollLanguageServerEvents(sessionID: String) -> [LanguageServerRuntimeEvent] {
        lock.withLock { events.removeValue(forKey: sessionID) ?? [] }
    }

    func syncLanguageServerDocument(
        sessionID _: String, fileURL _: URL, languageID _: String, text _: String
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure> {
        .success(LanguageServerDocumentSync(documentVersion: 1, changed: false))
    }

    func closeLanguageServerDocument(sessionID _: String, fileURL _: URL) {}

    func requestLanguageServerOperation(
        sessionID _: String, operation _: LanguageServerOperation, fileURL _: URL?, virtualURI _: String?,
        position _: LanguageServerPosition?, newName _: String?, range _: LanguageServerRange?,
        diagnostics _: [LanguageServerDiagnostic], completionItem _: LanguageServerCompletionItem?,
        codeAction _: LanguageServerCodeAction?, command _: LanguageServerCommand?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .success(LanguageServerRuntimeOperation(operationID: "unused"))
    }

    func cancelLanguageServerOperation(sessionID: String, operationID: String) {
        lock.withLock {
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
