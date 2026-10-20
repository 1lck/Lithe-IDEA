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
    let core = ScriptedProviderCore()
    let sessions: MacBuildProviderSessions

    var executableURL: URL { packageURL.appendingPathComponent(Self.executablePath) }

    init() throws {
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
            processRegistry: nil
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

/// Starts every session ready and answers each build request at once, so
/// the session's own event loop completes it on its next poll.
private final class ScriptedProviderCore: LanguageServerRuntimeCore, @unchecked Sendable {
    struct StartCall { let arguments: [String] }

    private let lock = NSLock()
    private var nextSession = 0
    private var events: [String: [LanguageServerRuntimeEvent]] = [:]
    private var _startCalls: [StartCall] = []
    private var _stopCalls: [String] = []
    private var _buildRequests: [String] = []

    var startCalls: [StartCall] { lock.withLock { _startCalls } }
    var stopCalls: [String] { lock.withLock { _stopCalls } }
    var buildRequests: [String] { lock.withLock { _buildRequests } }

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
        lock.withLock {
            nextSession += 1
            _startCalls.append(StartCall(arguments: arguments))
            return .success(LanguageServerRuntimeStart(sessionID: "provider-\(nextSession)", state: "ready", processID: nil))
        }
    }

    func stopLanguageServer(sessionID: String) {
        lock.withLock {
            _stopCalls.append(sessionID)
            events[sessionID, default: []].append(LanguageServerRuntimeEvent(type: "stateChanged", state: "stopped"))
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

    func cancelLanguageServerOperation(sessionID _: String, operationID _: String) {}
    func destroyLanguageServer(sessionID _: String) {}
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
