import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// The stdio transport of a plugin's debug adapter. The launch depends on the
/// workspace, so Rust Core plans it when the session starts, not when the
/// provider is registered; a rejected plan surfaces as the start error.
@MainActor
final class MacPluginDebugAdapterTransport: DebugAdapterTransport {
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

    private let resolve: @MainActor (URL) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterProcess
    private let adapterID: String
    private let makeProcess: @MainActor () -> any RawProcessSession
    /// Finds a system command by tool discovery. Never a project-local copy.
    private let findCommand: @MainActor ([String]) -> URL?
    private var transport: MacProcessDebugAdapterTransport?

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        adapterID: String,
        resolve: @escaping @MainActor (URL) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterProcess,
        makeProcess: @escaping @MainActor () -> any RawProcessSession,
        findCommand: @escaping @MainActor ([String]) -> URL? = { _ in nil }
    ) {
        self.adapterID = adapterID
        self.findCommand = findCommand
        self.resolve = resolve
        self.makeProcess = makeProcess
    }

    var isRunning: Bool { transport?.isRunning ?? false }

    func start(rootURL: URL) throws {
        let launch = try resolve(rootURL)
        let executableURL: URL
        switch launch.process.executable {
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
        let transport = MacProcessDebugAdapterTransport(
            executableURL: executableURL,
            arguments: launch.process.arguments,
            environment: ProcessInfo.processInfo.environment,
            process: makeProcess()
        )
        transport.onData = { [weak self] in self?.onData?($0) }
        transport.onErrorOutput = { [weak self] in self?.onErrorOutput?($0) }
        transport.onTermination = { [weak self] in self?.onTermination?($0) }
        self.transport = transport
        try transport.start(rootURL: rootURL)
    }

    func send(_ data: Data) throws {
        try transport?.send(data)
    }

    func stop() {
        transport?.stop()
    }
}
