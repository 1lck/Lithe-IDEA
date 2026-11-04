import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// The transport of a plugin's debug adapter: stdio to a process of its own,
/// or a loopback socket to an adapter the plugin's language server hosts. The
/// launch depends on the workspace, so Rust Core plans it when the session
/// starts, not when the provider is registered; a rejected plan surfaces as the
/// start error.
@MainActor
final class MacPluginDebugAdapterTransport: DebugAdapterDrainingTransport, DebugAdapterLaunchResolvingTransport {
    enum TransportError: LocalizedError, Equatable {
        case unsupportedExecutable(adapterID: String)
        case commandNotFound(adapterID: String, commands: [String])

        var errorDescription: String? {
            switch self {
            case .unsupportedExecutable(let adapterID):
                L10n.string("The debug adapter \(adapterID) must launch an executable from its plugin package.")
            case .commandNotFound(let adapterID, let commands):
                L10n.string("The debug adapter \(adapterID) needs \(commands.joined(separator: ", ")), which was not found. Install it, then try again.")
            }
        }
    }

    /// Starts the plugin's language server for the workspace, runs the
    /// declared debug-start command on it and returns the adapter's loopback
    /// port. The language module owns the server; this transport owns the socket.
    typealias HostedPortStarter = @MainActor (_ languageID: String, _ command: String, _ rootURL: URL) async throws -> UInt16

    private let resolve: @MainActor (URL) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterLaunch
    private let adapterID: String
    private let makeProcess: @MainActor () -> any RawProcessSession
    private let core: any DebugTransportLifecycleCore
    /// Finds a system command by tool discovery. Never a project-local copy.
    private let findCommand: @MainActor ([String]) -> URL?
    private let startHostedPort: HostedPortStarter
    private let socketFactory: @MainActor (String, UInt16) -> any DebugAdapterSocketConnection
    /// Runs a hosted adapter's discovery and connect deadlines; nil uses system timers.
    private let deadlineScheduler: (any DebugOperationDeadlineScheduling)?
    private let logSink: (any LogSink)?
    private var transport: (any DebugAdapterTransport)?
    var startupAttempt: PluginOperationAttempt?

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        adapterID: String,
        resolve: @escaping @MainActor (URL) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterLaunch,
        makeProcess: @escaping @MainActor () -> any RawProcessSession,
        core: any DebugTransportLifecycleCore,
        logSink: (any LogSink)? = nil,
        findCommand: @escaping @MainActor ([String]) -> URL? = { _ in nil },
        startHostedPort: @escaping HostedPortStarter = { _, _, _ in
            throw MacHostedPortDebugAdapterTransport.TransportError.languageIntelligenceUnavailable
        },
        socketFactory: @escaping @MainActor (String, UInt16) -> any DebugAdapterSocketConnection = {
            NetworkDebugAdapterSocketConnection(host: $0, port: $1)
        },
        deadlineScheduler: (any DebugOperationDeadlineScheduling)? = nil
    ) {
        self.adapterID = adapterID
        self.findCommand = findCommand
        self.resolve = resolve
        self.makeProcess = makeProcess
        self.core = core
        self.logSink = logSink
        self.startHostedPort = startHostedPort
        self.socketFactory = socketFactory
        self.deadlineScheduler = deadlineScheduler
    }

    var isRunning: Bool { transport?.isRunning ?? false }

    func start(rootURL: URL) throws {
        let transport: any DebugAdapterTransport
        let connectsLater: Bool
        switch try resolve(rootURL).host {
        case .process(let process):
            transport = try processTransport(for: process)
            connectsLater = false
        case .languageServer(let languageID, let command):
            let startHostedPort = startHostedPort
            let hosted = MacHostedPortDebugAdapterTransport(
                portResolver: { rootURL in try await startHostedPort(languageID, command, rootURL) },
                core: core,
                logSink: logSink,
                deadlineScheduler: deadlineScheduler,
                socketFactory: socketFactory
            )
            // Starting the server and finding the port outlive `start`, so the
            // attempt stays at launch until the socket connects. A failure
            // before then is the launch's, or the deadline's.
            let attempt = startupAttempt
            hosted.onConnected = { attempt?.advance(to: .initialize) }
            hosted.onFailure = { reason in
                guard reason == .startupTimedOut, attempt?.stage == .launch else { return }
                attempt?.advance(to: .timeout)
            }
            transport = hosted
            connectsLater = true
        }
        transport.onData = { [weak self] in self?.onData?($0) }
        transport.onErrorOutput = { [weak self] in self?.onErrorOutput?($0) }
        transport.onTermination = { [weak self] in self?.onTermination?($0) }
        self.transport = transport
        // The plan, the executable and the hosted command are known; what
        // fails from here is starting the adapter.
        startupAttempt?.advance(to: .launch)
        try transport.start(rootURL: rootURL)
        // A process adapter is reachable once it runs; what fails next is the handshake.
        if !connectsLater { startupAttempt?.advance(to: .initialize) }
    }

    private func processTransport(
        for process: MacPluginLanguageServerLaunchResolver.BuildProviderProcess
    ) throws -> MacProcessDebugAdapterTransport {
        let executableURL: URL
        switch process.executable {
        case .file(let url):
            executableURL = url
        case .commands(let commands):
            guard let url = findCommand(commands) else {
                throw TransportError.commandNotFound(adapterID: adapterID, commands: commands)
            }
            executableURL = url
        case .runtime:
            throw TransportError.unsupportedExecutable(adapterID: adapterID)
        }
        return MacProcessDebugAdapterTransport(
            executableURL: executableURL,
            arguments: process.arguments,
            environment: ProcessInfo.processInfo.environment,
            process: makeProcess()
        )
    }

    func send(_ data: Data) throws {
        try transport?.send(data)
    }

    func stop() {
        transport?.stop()
    }

    func finishSendingAndStop() {
        if let draining = transport as? any DebugAdapterDrainingTransport {
            draining.finishSendingAndStop()
        } else { transport?.stop() }
    }
}
