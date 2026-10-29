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

    init(prepareState: @escaping @Sendable (_ installation: PluginInstallationRecord, _ stateDirectory: URL) -> Void = { _, _ in }) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-backend-\(UUID().uuidString)", isDirectory: true)
        packageURL = root.appendingPathComponent("package", isDirectory: true)
        stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let fixtureURL = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/backend.plugin.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
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
            endBackendProcesses: { _, _ in }
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

    private let lock = NSLock()
    private var nextSession = 0
    private var events: [String: [LanguageServerRuntimeEvent]] = [:]
    private var _starts: [Start] = []
    private var _stops: [String] = []
    private var _responses: [Response] = []
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]

    var starts: [Start] { lock.withLock { _starts } }
    var stops: [String] { lock.withLock { _stops } }
    var responses: [Response] { lock.withLock { _responses } }

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
                LanguageServerRuntimeEvent(type: "stateChanged", state: "ready"),
            ]
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
