import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

/// The plugin backend table with a scripted runtime core and Rust Core's
/// real launch planning: where a backend starts, which host services it
/// receives, how its credential requests are answered, and when it stops.
@MainActor
struct MacPluginBackendSessionsTests {
    @Test
    func commandsWaitForInitializeAndRestartAfterExit() async throws {
        let fixture = try BackendFixture(backendVersion: 2, commandActivation: true)
        defer { fixture.remove() }
        fixture.core.delayReady = true
        let owner = ModuleID("\(BackendFixture.pluginID).ui")
        fixture.sessions.runCommand("dev.lithe.fixture.backend.open", owner: owner, context: nil)
        try #require(await fixture.core.started.waitUntilOpen())
        fixture.sessions.runCommand("dev.lithe.fixture.backend.open", owner: owner, context: nil)
        #expect(fixture.core.notifications.isEmpty)
        fixture.core.finishInitialize()
        try #require(await fixture.core.waitForNotifications(2))
        #expect(fixture.core.starts.count == 1)

        let disposed = TestGate()
        _ = fixture.sessions.hostDispatcher.subscriptions.add(pluginID: BackendFixture.pluginID, contextID: nil) { disposed.open() }
        fixture.core.exit()
        try #require(await disposed.waitUntilOpen())
        fixture.core.delayReady = false
        fixture.sessions.runCommand("dev.lithe.fixture.backend.open", owner: owner, context: nil)
        try #require(await fixture.core.waitForNotifications(3))
        #expect(fixture.core.starts.count == 2)
        #expect(fixture.core.notifications.last?.sessionID == "backend-2")
    }

    @Test
    func stoppingABlockedNotificationReleasesTheWriteOffMainActor() async throws {
        let fixture = try BackendFixture(backendVersion: 2)
        defer { fixture.core.releaseWrite.open(); fixture.remove() }
        _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)
        fixture.core.blockNotification = true
        fixture.sessions.runCommand("query.run", owner: ModuleID("\(BackendFixture.pluginID).ui"), context: nil)
        try #require(await fixture.core.writeStarted.waitUntilOpen())
        fixture.sessions.disable(BackendFixture.pluginID)
        try #require(await fixture.core.forcedStop.waitUntilOpen())
        try #require(await fixture.core.writeFinished.waitUntilOpen())
    }

    /// The first page call starts the backend in its own state directory,
    /// outside the package, with the services its permissions grant; later
    /// calls reuse the process.
    @Test
    func aPageCallStartsOneBackendInItsStateDirectoryWithItsHostServices() async throws {
        let fixture = try BackendFixture()
        defer { fixture.remove() }

        #expect(try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID) == ["query.run"])
        #expect(try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID) == ["query.run"])

        let starts = fixture.core.starts
        #expect(starts.count == 1)
        let stateDirectory = fixture.stateRoot
            .appendingPathComponent(BackendFixture.pluginID, isDirectory: true)
            .appendingPathComponent("backend", isDirectory: true)
        #expect(starts.first?.pluginID == BackendFixture.pluginID)
        #expect(starts.first?.hostServices == ["credentials"])
        #expect(starts.first?.rootURL.standardizedFileURL.path == stateDirectory.standardizedFileURL.path)
        #expect(starts.first?.arguments == ["--state", stateDirectory.standardizedFileURL.path])
        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))
    }

    /// Host migrations into a plugin's state finish before its backend
    /// starts, once per start, with the backend's own state directory.
    @Test
    func stateIsPreparedBeforeTheBackendStarts() async throws {
        let prepared = PreparedStates()
        let fixture = try BackendFixture { installation, stateDirectory in
            try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try? Data("moved".utf8).write(to: stateDirectory.appendingPathComponent("migrated.json"))
            prepared.record(pluginID: installation.pluginID.rawValue, stateDirectory: stateDirectory)
        }
        defer { fixture.remove() }

        _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)

        let stateDirectory = try #require(fixture.core.starts.first?.rootURL)
        #expect(prepared.calls == [.init(pluginID: BackendFixture.pluginID, path: stateDirectory.standardizedFileURL.path)])
        #expect(FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("migrated.json").path))
    }

    /// A credential request is answered from the plugin's own entries, and
    /// a store failure reaches the backend without the secret.
    @Test
    func credentialRequestsAreAnsweredFromThePluginsOwnStore() async throws {
        let fixture = try BackendFixture()
        defer { fixture.remove() }
        try fixture.credentials.setSecret("other", pluginID: "dev.example.other", key: "connection.prod")
        _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)

        fixture.core.sendHostRequest(
            id: "host-1", method: "lithe/host/credentials/set",
            params: .object(["key": .string("connection.prod"), "secret": .string("s3cret")])
        )
        #expect(await fixture.core.waitForResponses(1))
        fixture.core.sendHostRequest(
            id: "host-2", method: "lithe/host/credentials/get", params: .object(["key": .string("connection.prod")])
        )
        #expect(await fixture.core.waitForResponses(2))
        fixture.core.sendHostRequest(
            id: "host-3", method: "lithe/host/credentials/delete", params: .object(["key": .string("connection.prod")])
        )
        #expect(await fixture.core.waitForResponses(3))

        #expect(fixture.core.responses == [
            .init(id: "host-1", outcome: .success(.null)),
            .init(id: "host-2", outcome: .success(.object(["secret": .string("s3cret")]))),
            .init(id: "host-3", outcome: .success(.null)),
        ])
        #expect(try fixture.credentials.secret(pluginID: BackendFixture.pluginID, key: "connection.prod") == nil)
        #expect(try fixture.credentials.secret(pluginID: "dev.example.other", key: "connection.prod") == "other")
    }

    /// Disabling stops the backend and refuses calls until the plugin is
    /// enabled again; a replaced package never starts again in this launch.
    @Test
    func disablingAndReplacingThePackageStopTheBackend() async throws {
        let fixture = try BackendFixture()
        defer { fixture.remove() }
        _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)

        fixture.sessions.disable(BackendFixture.pluginID)
        #expect(fixture.core.stops.count == 1)
        await #expect(throws: PluginFunctionFailure.self) {
            _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)
        }

        fixture.sessions.enable(BackendFixture.pluginID)
        _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)
        #expect(fixture.core.starts.count == 2)

        fixture.sessions.packageWillChange(BackendFixture.pluginID)
        #expect(fixture.core.stops.count == 2)
        fixture.sessions.enable(BackendFixture.pluginID)
        #expect(!fixture.sessions.declaresBackend(BackendFixture.pluginID))
        await #expect(throws: PluginFunctionFailure.self) {
            _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)
        }
    }

    /// A command run from the plugin's UI and the events of its
    /// subscriptions reach the running backend as host notifications, in
    /// the order the host sent them.
    @Test
    func commandsAndSubscriptionEventsReachTheRunningBackendInOrder() async throws {
        let fixture = try BackendFixture(backendVersion: 2)
        defer { fixture.remove() }
        _ = try await fixture.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)
        let owner = ModuleID("\(BackendFixture.pluginID).ui")
        let subscriptions = fixture.sessions.hostDispatcher.subscriptions
        let subscriptionID = subscriptions.add(pluginID: BackendFixture.pluginID, contextID: nil) {}
        let window = NSObject()
        let context = fixture.sessions.hostDispatcher.contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/fixture/project"), remote: nil)
        defer { fixture.sessions.hostDispatcher.contexts.close(owner: window) }

        fixture.sessions.runCommand(
            "query.run", owner: owner,
            context: context.reference
        )
        subscriptions.notify(pluginID: BackendFixture.pluginID, subscriptionID: subscriptionID, event: ["kind": .string("changed")])
        fixture.sessions.runCommand("query.stop", owner: owner, context: nil)

        #expect(await fixture.core.waitForNotifications(3))
        #expect(fixture.core.notifications.map(\.method) == [
            "lithe/host/commands/didRun", "lithe/host/subscriptions/notify", "lithe/host/commands/didRun",
        ])
        #expect(fixture.core.notifications.first?.params == .object([
            "commandID": .string("query.run"),
            "context": .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)]),
        ]))
        #expect(fixture.core.notifications.last?.params == .object(["commandID": .string("query.stop")]))
    }

    /// A version 1 backend has no command notification, and a command that
    /// is not an activation event does not start a stopped backend.
    @Test
    func aCommandReachesNoBackendThatCannotReceiveIt() async throws {
        let first = try BackendFixture()
        defer { first.remove() }
        _ = try await first.sessions.pluginFunctions(ofPlugin: BackendFixture.pluginID)
        first.sessions.runCommand("query.run", owner: ModuleID("\(BackendFixture.pluginID).ui"), context: nil)
        #expect(first.core.notifications.isEmpty)

        let stopped = try BackendFixture(backendVersion: 2)
        defer { stopped.remove() }
        stopped.sessions.runCommand("query.run", owner: ModuleID("\(BackendFixture.pluginID).ui"), context: nil)
        stopped.sessions.runCommand("query.run", owner: ModuleID("dev.example.other.ui"), context: nil)
        #expect(stopped.core.starts.isEmpty)
        #expect(stopped.core.notifications.isEmpty)
    }

    /// The answer never echoes a secret, and a request outside the
    /// credentials service is refused even if Core forwarded it.
    @Test
    func hostServiceFailuresNeverCarryTheSecret() {
        let failing = FailingCredentialStore()
        let set = PluginHostServices.answer(
            PluginHostRequest(
                id: "host-1", method: "lithe/host/credentials/set", service: "credentials",
                params: .object(["key": .string("k"), "secret": .string("top-secret")])
            ),
            pluginID: BackendFixture.pluginID, credentials: failing
        )
        guard case .failure(let failure) = set else {
            Issue.record("A store failure must fail the request.")
            return
        }
        #expect(!failure.message.contains("top-secret"))

        let other = PluginHostServices.answer(
            PluginHostRequest(id: "host-2", method: "lithe/host/process/run", service: "process", params: .object([:])),
            pluginID: BackendFixture.pluginID, credentials: MemoryPluginCredentialStore()
        )
        #expect((try? other.get()) == nil)
    }
}

private struct FailingCredentialStore: PluginCredentialStoring {
    struct Locked: LocalizedError { var errorDescription: String? { "The Keychain is locked." } }
    func secret(pluginID _: String, key _: String) throws -> String? { throw Locked() }
    func setSecret(_: String, pluginID _: String, key _: String) throws { throw Locked() }
    func deleteSecret(pluginID _: String, key _: String) throws { throw Locked() }
    func deleteAll(pluginID _: String) throws { throw Locked() }
}

/// The state preparations a fixture's sessions ran, from any thread.
private final class PreparedStates: @unchecked Sendable {
    struct Call: Equatable {
        let pluginID: String
        let path: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] { lock.withLock { recorded } }

    func record(pluginID: String, stateDirectory: URL) {
        lock.withLock { recorded.append(Call(pluginID: pluginID, path: stateDirectory.standardizedFileURL.path)) }
    }
}

/// The backend fixture of the shared contract as an installed package.
@MainActor
private struct BackendFixture {
    static let pluginID = "dev.lithe.fixture.backend"

    let root: URL
    let packageURL: URL
    let stateRoot: URL
    let credentials = MemoryPluginCredentialStore()
    let core = ScriptedBackendCore()
    let sessions: MacPluginBackendSessions

    init(
        backendVersion: Int = 1,
        commandActivation: Bool = false,
        prepareState: @escaping @Sendable (_ installation: PluginInstallationRecord, _ stateDirectory: URL) -> Void = { _, _ in }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-backend-\(UUID().uuidString)", isDirectory: true)
        packageURL = root.appendingPathComponent("package", isDirectory: true)
        stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let fixtureURL = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/backend.plugin.json")
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        if var requires = object["requires"] as? [String: Any] {
            requires["backend"] = backendVersion
            object["requires"] = requires
        }
        if commandActivation {
            var ui = object["ui"] as? [String: Any] ?? [:]
            let windows = ui["toolWindows"] as? [[String: Any]] ?? []
            let commandID = "dev.lithe.fixture.backend.open"
            ui["commands"] = [["id": commandID, "title": "Open", "toolWindowID": windows[0]["id"]!, "placements": ["commandPalette"]]]
            object["ui"] = ui
            object["activationEvents"] = (object["activationEvents"] as? [String] ?? []) + ["onCommand:\(commandID)"]
        }
        _ = try DeclarativePluginTestSupport.writePackage(at: packageURL, manifest: object)
        let executable = packageURL.appendingPathComponent("bin/backend")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let operations = DeclarativePluginTestSupport.operations
        let descriptor = try operations.validate(manifest: Data(contentsOf: packageURL.appendingPathComponent("plugin.json")))
        #expect(descriptor.declaresBackend)

        sessions = MacPluginBackendSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(
                planner: operations,
                directories: MacPluginStateDirectories(rootURL: stateRoot),
                settings: InMemoryPluginSettings()
            ),
            tools: UnusedBackendTools(),
            versionChecker: operations,
            runtime: EmptyBackendToolRuntime(),
            core: core,
            processRegistry: nil,
            credentials: credentials,
            prepareState: prepareState,
            stuckSendGrace: .milliseconds(20),
            endBackendProcesses: { [core] _, immediately in
                if immediately { core.forcedStop.open(); core.releaseWrite.open() }
            }
        )
        sessions.register([InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id, activeVersion: descriptor.pluginManifest.version, origin: .localDevelopment
            ),
            packageURL: packageURL
        )])
    }

    func remove() {
        sessions.packageWillChange(Self.pluginID)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Starts ready plugin backends, queues host requests on demand, and
/// records how the host answered them.
private final class ScriptedBackendCore: LanguageServerRuntimeCore, @unchecked Sendable {
    struct Start {
        let pluginID: String
        let arguments: [String]
        let rootURL: URL
        let hostServices: [String]
    }

    struct Response: Equatable {
        let id: String
        let outcome: Result<ToolingJSONValue, PluginHostRequestFailure>
    }

    struct Notification: Equatable {
        let sessionID: String
        let method: String
        let params: ToolingJSONValue
    }

    private let lock = NSLock()
    private var nextSession = 0
    private var events: [String: [LanguageServerRuntimeEvent]] = [:]
    private var _starts: [Start] = []
    private var _stops: [String] = []
    private var _responses: [Response] = []
    private var _notifications: [Notification] = []
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var notificationWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var _delayReady = false
    private var _blockNotification = false
    let started = TestGate()
    let writeStarted = TestGate()
    let releaseWrite = TestGate()
    let writeFinished = TestGate()
    let forcedStop = TestGate()
    var delayReady: Bool { get { lock.withLock { _delayReady } } set { lock.withLock { _delayReady = newValue } } }
    var blockNotification: Bool { get { lock.withLock { _blockNotification } } set { lock.withLock { _blockNotification = newValue } } }

    func finishInitialize() {
        lock.withLock { events["backend-\(nextSession)", default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "ready")) }
    }

    func exit() {
        lock.withLock { events["backend-\(nextSession)", default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "stopped")) }
    }

    var starts: [Start] { lock.withLock { _starts } }
    var stops: [String] { lock.withLock { _stops } }
    var responses: [Response] { lock.withLock { _responses } }
    var notifications: [Notification] { lock.withLock { _notifications } }

    func startPluginLanguageServer(
        pluginID: String, providerID _: String, executableURL _: URL, arguments: [String],
        environment _: [String: String], rootURL: URL, initializationOptions _: ToolingJSONValue?,
        hostServices: [String], initializeTimeout _: TimeInterval, requestTimeout _: TimeInterval,
        shutdownTimeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lock.withLock {
            nextSession += 1
            let sessionID = "backend-\(nextSession)"
            _starts.append(Start(pluginID: pluginID, arguments: arguments, rootURL: rootURL, hostServices: hostServices))
            events[sessionID, default: []] += [
                LanguageServerRuntimeEvent(
                    type: "functionsChanged",
                    result: .object(["functions": .array([.string("query.run")]), "removed": .array([])])
                ),
            ]
            if !_delayReady { events[sessionID, default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "ready")) }
            started.open()
            return .success(LanguageServerRuntimeStart(sessionID: sessionID, state: "initializing", processID: nil))
        }
    }

    /// Queues a request Core accepted on the newest session.
    func sendHostRequest(id: String, method: String, params: ToolingJSONValue) {
        lock.withLock {
            events["backend-\(nextSession)", default: []].append(LanguageServerRuntimeEvent(
                type: "hostRequest",
                result: .object(["hostRequestID": .string(id), "service": .string("credentials"), "params": params]),
                method: method
            ))
        }
    }

    func respondToPluginHostRequest(
        sessionID _: String, hostRequestID: String, outcome: Result<ToolingJSONValue, PluginHostRequestFailure>
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        let satisfied = lock.withLock {
            _responses.append(Response(id: hostRequestID, outcome: outcome))
            let ready = waiters.filter { $0.value.count <= _responses.count }
            ready.keys.forEach { waiters.removeValue(forKey: $0) }
            return ready.values.map(\.continuation)
        }
        satisfied.forEach { $0.resume(returning: true) }
        return .success(())
    }

    /// Answers arrive off the main actor. The next answer resumes the
    /// waiter; a watchdog fails it after five seconds instead of hanging.
    func waitForResponses(_ count: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let ready: Bool = lock.withLock {
                guard _responses.count < count else { return true }
                waiters[id] = (count, continuation)
                return false
            }
            if ready { return continuation.resume(returning: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume(returning: false)
            }
        }
    }

    func notifyPluginBackend(
        sessionID: String, method: String, params: ToolingJSONValue
    ) -> Result<Bool, LanguageServerRuntimeFailure> {
        if blockNotification {
            writeStarted.open()
            defer { writeFinished.open() }
            // Native synchronous transport is exercised on its owned worker.
            guard releaseWrite.waitSynchronously(timeout: 5) else {
                return .failure(LanguageServerRuntimeFailure(code: "timeout", message: "write watchdog did not terminate"))
            }
            return .failure(LanguageServerRuntimeFailure(code: "processFailed", message: "backend ended"))
        }
        let satisfied = lock.withLock {
            _notifications.append(Notification(sessionID: sessionID, method: method, params: params))
            let ready = notificationWaiters.filter { $0.value.count <= _notifications.count }
            ready.keys.forEach { notificationWaiters.removeValue(forKey: $0) }
            return ready.values.map(\.continuation)
        }
        satisfied.forEach { $0.resume(returning: true) }
        return .success(true)
    }

    /// Notifications are sent off the main actor; like `waitForResponses`,
    /// a watchdog fails the wait after five seconds instead of hanging.
    func waitForNotifications(_ count: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let ready: Bool = lock.withLock {
                guard _notifications.count < count else { return true }
                notificationWaiters[id] = (count, continuation)
                return false
            }
            if ready { return continuation.resume(returning: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                lock.withLock { notificationWaiters.removeValue(forKey: id) }?.continuation.resume(returning: false)
            }
        }
    }

    func startLanguageServer(
        providerID _: String, executableURL _: URL, arguments _: [String], environment _: [String: String],
        rootURL _: URL, workingDirectoryURL _: URL, initializationOptions _: ToolingJSONValue?,
        runtimeExecutableURL _: URL?, jdtlsLaunchResources _: JDTLSLaunchResources?, cacheDirectoryURL _: URL?,
        workspaceFingerprint _: String?, initializeTimeout _: TimeInterval, requestTimeout _: TimeInterval,
        shutdownTimeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(code: "unexpected", message: "A backend is plugin-owned."))
    }

    func stopLanguageServer(sessionID: String) {
        lock.withLock {
            _stops.append(sessionID)
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "stopped"))
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
        diagnostics _: [LanguageServerDiagnostic], completionContext: LanguageServerCompletionContext?, completionItem _: LanguageServerCompletionItem?,
        codeAction _: LanguageServerCodeAction?, command _: LanguageServerCommand?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .success(LanguageServerRuntimeOperation(operationID: "unused"))
    }

    func cancelLanguageServerOperation(sessionID _: String, operationID _: String) {}
    func destroyLanguageServer(sessionID _: String) {}
}

/// The packaged backend never goes through tool discovery.
private final class UnusedBackendTools: BuildToolResolving {
    struct Unexpected: Error {}

    func resolve(
        _: BuildInvocation, displayName _: String, workspaceURL _: URL,
        checkVersion _: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        throw Unexpected()
    }
}

private final class EmptyBackendToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools _: [String]) -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}
