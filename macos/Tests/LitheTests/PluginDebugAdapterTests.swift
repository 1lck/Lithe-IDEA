import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheDebugModule
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Plugin debug adapter host")
@MainActor
struct PluginDebugAdapterTests {
    private struct ResolveFailure: Error, Equatable {}

    private static func process(_ executable: MacPluginLanguageServerLaunchResolver.BuildProviderProcess.Executable)
        -> MacPluginLanguageServerLaunchResolver.DebugAdapterLaunch
    {
        .init(
            host: .process(.init(
                executable: executable, arguments: [], initializationOptions: nil, runtimeTools: [],
                executesProjectCode: true, mayUseNetwork: false, settings: [:]
            )),
            adapter: .init(
                id: "lldb", providerID: "acme/lldb", displayName: "LLDB", adapterID: "lldb-dap",
                requests: ["launch"], languageIDs: ["rust"]
            )
        )
    }

    private static func hostedLaunch(
        languageID: String = "example", command: String = "example.startDebugSession"
    ) -> MacPluginLanguageServerLaunchResolver.DebugAdapterLaunch {
        .init(
            host: .languageServer(languageID: languageID, command: command),
            adapter: .init(
                id: "example", providerID: "acme/example", displayName: "Example Debugger",
                adapterID: "example-dap", requests: ["launch"], languageIDs: [languageID],
                transport: "tcpLanguageServer",
                languageServerEndpoint: .init(languageID: languageID, command: command)
            )
        )
    }

    @Test
    func aMissingSystemCommandFailsTheStartWithInstallGuidance() {
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "lldb",
            resolve: { _ in Self.process(.commands(["lldb-dap"])) },
            makeProcess: { Issue.record("No process starts for a missing command."); fatalError() },
            findCommand: { _ in nil }
        )
        #expect(throws: MacPluginDebugAdapterTransport.TransportError.commandNotFound(adapterID: "lldb", commands: ["lldb-dap"])) {
            try transport.start(rootURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true))
        }
        #expect(!transport.isRunning)
    }

    @Test
    func aRejectedLaunchPlanSurfacesAsTheStartError() {
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "lldb",
            resolve: { _ in throw ResolveFailure() },
            makeProcess: { Issue.record("No process starts when the plan is rejected."); fatalError() }
        )
        #expect(throws: ResolveFailure()) {
            try transport.start(rootURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true))
        }
    }

    // MARK: - Launch transport

    /// Resolves the fixture's `native` adapter, declared over `transport`.
    private func resolveNativeAdapter(
        transport: String,
        endpoint: [String: Any]? = nil
    ) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterLaunch {
        try resolveFixtureAdapter(fixture: "debug-adapter", adapterID: "native") { launch in
            launch["transport"] = transport
            launch["endpoint"] = endpoint
        }
    }

    /// Resolves one adapter of a contract fixture, after `editLaunch` changed
    /// the `launch` object the fixture declares.
    private func resolveFixtureAdapter(
        fixture: String,
        adapterID: String,
        editLaunch: (inout [String: Any]) -> Void = { _ in }
    ) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterLaunch {
        let url = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/\(fixture).plugin.json")
        var manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var adapters = try #require(manifest["debugAdapters"] as? [[String: Any]])
        let index = try #require(adapters.firstIndex { $0["id"] as? String == adapterID })
        var launch = try #require(adapters[index]["launch"] as? [String: Any])
        editLaunch(&launch)
        adapters[index]["launch"] = launch
        manifest["debugAdapters"] = adapters

        let operations = DeclarativePluginTestSupport.operations
        let descriptor = try operations.validate(manifest: JSONSerialization.data(withJSONObject: manifest))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-debug-transport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = MacPluginLanguageServerLaunchResolver(
            planner: operations,
            directories: MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true)),
            settings: InMemoryPluginSettings()
        )
        return try resolver.resolveDebugAdapter(
            pluginID: descriptor.id.rawValue,
            adapterID: adapterID,
            manifest: descriptor.normalizedManifest,
            packageURL: root.appendingPathComponent("package", isDirectory: true),
            workspaceRootURL: root.appendingPathComponent("workspace", isDirectory: true)
        )
    }

    @Test
    func aStdioAdapterResolvesToItsOwnProcess() throws {
        let resolved = try resolveNativeAdapter(transport: "stdio")
        #expect(resolved.adapter.transport == "stdio")
        guard case .process = resolved.host else {
            Issue.record("A stdio adapter runs as a process of its own, got \(resolved.host).")
            return
        }
    }

    /// The adapter lives inside the plugin's language server: nothing is
    /// started for it here, and the host learns which server and which command.
    @Test
    func aLanguageServerHostedAdapterResolvesToItsServerAndCommand() throws {
        let resolved = try resolveFixtureAdapter(fixture: "debug-adapter-language-server", adapterID: "example")
        #expect(resolved.adapter.transport == "tcpLanguageServer")
        #expect(resolved.adapter.languageServerEndpoint == .init(languageID: "example", command: "example.startDebugSession"))
        #expect(resolved.host == .languageServer(languageID: "example", command: "example.startDebugSession"))
    }

    /// Without an endpoint there is no server to ask for a port, so Core
    /// refuses the declaration before the host plans anything.
    @Test
    func aLanguageServerHostedAdapterWithoutAnEndpointIsRefused() {
        do {
            _ = try resolveFixtureAdapter(fixture: "debug-adapter-language-server", adapterID: "example") { launch in
                launch["endpoint"] = nil
            }
            Issue.record("A tcpLanguageServer adapter without an endpoint must not resolve.")
        } catch let rejection as DeclarativePluginRejection {
            #expect(rejection.field?.hasSuffix(".endpoint") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// A TCP adapter a process would have to announce is not reachable from
    /// the host, so it is refused before any process exists.
    @Test(arguments: ["tcpPort", "tcpAnnounced"])
    func aTCPAdapterIsRefusedBeforeItsProcessIsStarted(_ transport: String) {
        let endpoint: [String: Any] = transport == "tcpPort"
            ? ["port": 4711]
            : ["stream": "stdout", "prefix": "listening on ", "value": "port"]
        do {
            _ = try resolveNativeAdapter(transport: transport, endpoint: endpoint)
            Issue.record("A \(transport) adapter must not resolve to a process.")
        } catch let rejection as DeclarativePluginRejection {
            #expect(rejection.code == "plugin.launch.unsupportedTransport")
            #expect(rejection.field == "debugAdapters.launch.transport")
            #expect(rejection.message.contains(transport))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func unknownProvidersFallBackToThePluginLaunch() throws {
        let document = URL(fileURLWithPath: "/tmp/workspace/src/main.zig")
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let provider = LanguageProviderDescriptor(
            id: "zig", displayName: "Zig", fileExtensions: ["zig"],
            capabilities: [.debugAdapter], activationPolicy: .onDemand
        )
        var asked: [String] = []
        let resolver = DebugLaunchConfigurationResolver(
            pluginLaunch: { languageID, _, _ in
                asked.append(languageID)
                return DebugLaunchConfiguration(name: "main.zig", request: .launch, arguments: [:])
            }
        )
        let configuration = try resolver.resolve(
            provider: provider, documentURL: document, workspaceURL: root,
            configurations: [], selectedConfiguration: nil, javaTarget: nil, options: { _ in RunOptions() }
        )
        #expect(asked == ["zig"])
        #expect(configuration.name == "main.zig")

        let without = DebugLaunchConfigurationResolver()
        #expect(throws: DebugLaunchConfigurationResolutionError.self) {
            try without.resolve(
                provider: provider, documentURL: document, workspaceURL: root,
                configurations: [], selectedConfiguration: nil, javaTarget: nil, options: { _ in RunOptions() }
            )
        }
    }

    // MARK: - Language server hosted transport

    @Test(arguments: [false, true], [false, true])
    func aHostedAdapterActivatesItsLanguageModuleWithoutAnOpenDocument(disabled: Bool, foreign: Bool) async throws {
        let pluginID = "dev.example.debugger"
        let languageID = "example"
        let runtime = ModuleRuntime()
        let factory = HostedLanguageRuntimeFactory()
        let sessions = LanguageToolingSessionManager(runtimeFactory: factory)
        let support = LanguageSupportDeclaration(
            id: languageID, displayName: "Example", fileExtensions: ["ex"],
            languageServerModuleID: .languageServerExtension(languageID)
        )
        let manifest = ModuleManifest(
            id: .languageServerExtension(languageID), displayName: "Example", scope: .workspace,
            providedCapabilities: [.languageServerExtension(languageID)]
        )
        let configuration = LanguageServerExtensionConfiguration(
            languageID: languageID, displayName: "Example", executableNames: ["example-ls"],
            languageIdentifier: languageID,
            launchSource: .init(
                pluginID: foreign ? "dev.example.other" : pluginID, languageID: languageID,
                manifest: Data(), packageURL: URL(fileURLWithPath: "/plugins/example")
            )
        )
        try runtime.register(ModuleFactory(manifest: manifest) {
            BundledLanguageServerModule(manifest: manifest, configuration: configuration)
        }, enabled: !disabled)
        var prepared: [String] = []

        try await WorkbenchTestScope.withCleanup({
            sessions.stopAllLanguageServers()
            await runtime.shutdownAll()
        }) { _ in
            #expect(sessions.languageServerExtensionDescriptor(languageID: languageID) == nil)
            let prepare = {
                try await MacServiceContainer.prepareHostedDebugAdapterLanguageServer(
                    languageID: languageID, pluginID: pluginID, supports: [support],
                    runtime: runtime, sessions: sessions,
                    prepareTools: { prepared.append($0.id) }
                )
            }
            if disabled || foreign {
                await #expect(throws: LanguageToolingSessionError.languageServerNotOwnedByPlugin(languageID: languageID)) {
                    try await prepare()
                }
                #expect(factory.calls == 0)
                #expect(prepared.isEmpty)
            } else {
                try await prepare()
                try await prepare()
                #expect(factory.calls == 1)
                #expect(prepared == [languageID, languageID])
                #expect(sessions.languageServerExtensionDescriptor(languageID: languageID)?
                    .languageServerLaunch?.launchSource?.pluginID == pluginID)
            }
        }
    }

    /// The event order is: the transport asks the language module for the port
    /// of the declared command, opens a loopback socket to it, and releases
    /// the bytes queued meanwhile only once that socket is ready.
    @Test
    func aLanguageServerHostedAdapterConnectsToThePortItsServerReports() async throws {
        let probe = HostedAdapterProbe()
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "example",
            resolve: { _ in Self.hostedLaunch() },
            makeProcess: { Issue.record("A hosted adapter starts no process of its own."); fatalError() },
            startHostedPort: { languageID, command, rootURL in
                probe.recordPortRequest(languageID: languageID, command: command, rootURL: rootURL)
                return 4711
            },
            socketFactory: { host, port in probe.makeSocket(host: host, port: port) }
        )
        defer { transport.stop() }
        let root = URL(fileURLWithPath: "/tmp/hosted-adapter", isDirectory: true)
        let initializeFrame = Data("Content-Length: 2\r\n\r\n{}".utf8)

        try transport.start(rootURL: root)
        try transport.send(initializeFrame)
        #expect(await probe.waitUntilConnected(), "The socket was not opened before the local deadline")

        #expect(probe.portRequests == [
            .init(languageID: "example", command: "example.startDebugSession", rootURL: root.standardizedFileURL)
        ])
        #expect(probe.endpoints == [.init(host: "127.0.0.1", port: 4711)])
        #expect(probe.socket.startCount == 1)
        #expect(probe.socket.sent.isEmpty)

        probe.socket.onReady?()
        #expect(probe.socket.sent == [initializeFrame])
        transport.stop()
        #expect(probe.socket.stopCount == 1)
        #expect(!transport.isRunning)
    }

    /// A server that cannot start the adapter ends the session with its own
    /// reason; no socket is opened without a port.
    @Test
    func aLanguageServerThatCannotHostTheAdapterEndsTheSessionWithItsReason() async throws {
        struct Unavailable: LocalizedError { var errorDescription: String? { "The Example language server did not start." } }
        let probe = HostedAdapterProbe()
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "example",
            resolve: { _ in Self.hostedLaunch() },
            makeProcess: { Issue.record("A hosted adapter starts no process of its own."); fatalError() },
            startHostedPort: { _, _, _ in throw Unavailable() },
            socketFactory: { host, port in
                Issue.record("No socket opens without a port.")
                return probe.makeSocket(host: host, port: port)
            }
        )
        defer { transport.stop() }
        transport.onErrorOutput = { probe.recordErrorOutput($0) }
        transport.onTermination = { probe.recordTermination($0) }

        try transport.start(rootURL: URL(fileURLWithPath: "/tmp/hosted-adapter-failure", isDirectory: true))
        #expect(await probe.waitUntilTerminated(), "The session did not end before the local deadline")

        #expect(probe.terminationCodes == [1])
        #expect(probe.errorOutput == "The Example language server did not start.\n")
        #expect(probe.endpoints.isEmpty)
        #expect(!transport.isRunning)
    }

    /// Without the language module the default starter refuses the adapter
    /// instead of leaving the session waiting for a port.
    @Test
    func aLanguageServerHostedAdapterWithoutALanguageServiceEndsTheSession() async throws {
        let probe = HostedAdapterProbe()
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "example",
            resolve: { _ in Self.hostedLaunch() },
            makeProcess: { Issue.record("A hosted adapter starts no process of its own."); fatalError() }
        )
        defer { transport.stop() }
        transport.onErrorOutput = { probe.recordErrorOutput($0) }
        transport.onTermination = { probe.recordTermination($0) }

        try transport.start(rootURL: URL(fileURLWithPath: "/tmp/hosted-adapter-unwired", isDirectory: true))
        #expect(await probe.waitUntilTerminated(), "The session did not end before the local deadline")

        #expect(probe.terminationCodes == [1])
        let unavailable = MacHostedPortDebugAdapterTransport.TransportError.languageIntelligenceUnavailable
        #expect(probe.errorOutput == unavailable.localizedDescription + "\n")
    }
}

@MainActor
private final class HostedLanguageRuntimeFactory: LanguageProviderRuntimeFactory {
    private(set) var calls = 0
    func makeRuntime(for _: LanguageProviderDescriptor) -> (any LanguageProviderRuntime)? { nil }
    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch _: LanguageServerLaunchDescriptor,
        ownerModuleID _: ModuleID
    ) -> (any LanguageProviderRuntime)? {
        calls += 1
        return HostedLanguageRuntime(descriptor: descriptor)
    }
}

@MainActor
private final class HostedLanguageRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    init(descriptor: LanguageProviderDescriptor) { self.descriptor = descriptor }
}

/// What a language server hosted adapter did, in the order it happened.
@MainActor
private final class HostedAdapterProbe {
    struct PortRequest: Equatable {
        let languageID: String
        let command: String
        let rootURL: URL
    }

    struct Endpoint: Equatable {
        let host: String
        let port: UInt16
    }

    let socket = HostedAdapterSocket()
    private(set) var portRequests: [PortRequest] = []
    private(set) var endpoints: [Endpoint] = []
    private(set) var errorOutput = ""
    private(set) var terminationCodes: [Int] = []
    private let connected = EventLatch()
    private let terminated = EventLatch()

    func recordPortRequest(languageID: String, command: String, rootURL: URL) {
        portRequests.append(PortRequest(languageID: languageID, command: command, rootURL: rootURL))
    }

    func makeSocket(host: String, port: UInt16) -> any DebugAdapterSocketConnection {
        endpoints.append(Endpoint(host: host, port: port))
        connected.fire()
        return socket
    }

    func recordErrorOutput(_ data: Data) {
        errorOutput += String(decoding: data, as: UTF8.self)
    }

    func recordTermination(_ code: Int) {
        terminationCodes.append(code)
        terminated.fire()
    }

    func waitUntilConnected() async -> Bool { await connected.wait(deadline: .seconds(8)) }
    func waitUntilTerminated() async -> Bool { await terminated.wait(deadline: .seconds(8)) }
}

@MainActor
private final class HostedAdapterSocket: DebugAdapterSocketConnection {
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onComplete: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [Data] = []

    func start() { startCount += 1 }
    func send(_ data: Data, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        sent.append(data)
        completion(.success(()))
    }
    func stop() { stopCount += 1 }
}

/// Remembers that an event happened and resumes one waiter when it does. Both
/// the event and the local deadline arrive on the main actor, so a passing run
/// returns on the event and the deadline only bounds a failing one.
@MainActor
private final class EventLatch {
    private var fired = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func fire() {
        fired = true
        resume(true)
    }

    func wait(deadline: DispatchTimeInterval) async -> Bool {
        if fired { return true }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
                MainActor.assumeIsolated { self?.resume(false) }
            }
        }
    }

    private func resume(_ value: Bool) {
        guard let pending = waiter else { return }
        waiter = nil
        pending.resume(returning: value)
    }
}
