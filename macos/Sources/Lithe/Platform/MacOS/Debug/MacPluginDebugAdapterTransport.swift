import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// The stdio transport of a plugin's debug adapter. The launch depends on the
/// workspace, so Rust Core plans it when the session starts, not when the
/// provider is registered; a rejected plan surfaces as the start error.
@MainActor
final class MacPluginDebugAdapterTransport: DebugAdapterTransport {
    enum TransportError: LocalizedError {
        case unsupportedExecutable(adapterID: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedExecutable(let adapterID):
                L10n.string("The debug adapter \(adapterID) must launch an executable from its plugin package.")
            }
        }
    }

    private let resolve: @MainActor (URL) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterProcess
    private let adapterID: String
    private let makeProcess: @MainActor () -> any RawProcessSession
    private var transport: MacProcessDebugAdapterTransport?

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        adapterID: String,
        resolve: @escaping @MainActor (URL) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterProcess,
        makeProcess: @escaping @MainActor () -> any RawProcessSession
    ) {
        self.adapterID = adapterID
        self.resolve = resolve
        self.makeProcess = makeProcess
    }

    var isRunning: Bool { transport?.isRunning ?? false }

    func start(rootURL: URL) throws {
        let launch = try resolve(rootURL)
        guard case .file(let executableURL) = launch.process.executable else {
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
