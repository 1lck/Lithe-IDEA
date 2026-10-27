import LitheModuleAPI
import Foundation
import LitheCoreContracts

/// Connects the macOS product to a debug adapter hosted inside a language
/// server, such as the Java Debug Server inside JDT LS. Language server
/// activation stays in the language module and DAP state stays in Core; this
/// transport owns only asynchronous port discovery and the native TCP socket.
@MainActor
final class MacHostedPortDebugAdapterTransport: DebugAdapterDrainingTransport {
    enum TransportError: LocalizedError {
        case languageIntelligenceUnavailable
        case connectionFailed(String)
        case stopped

        var errorDescription: String? {
            switch self {
            case .languageIntelligenceUnavailable:
                return L10n.string("The language service that hosts the debug adapter is unavailable.")
            case .connectionFailed(let message):
                return L10n.string("Could not connect to the Debug Adapter: \(message)")
            case .stopped:
                return L10n.string("The debug adapter connection is stopped.")
            }
        }
    }

    typealias PortResolver = @MainActor (URL) async throws -> UInt16

    private let transport: MacTCPDebugAdapterTransport
    var isRunning: Bool { transport.isRunning }
    var onData: ((Data) -> Void)? {
        get { transport.onData }
        set { transport.onData = newValue }
    }
    var onErrorOutput: ((Data) -> Void)? {
        get { transport.onErrorOutput }
        set { transport.onErrorOutput = newValue }
    }
    var onTermination: ((Int) -> Void)? {
        get { transport.onTermination }
        set { transport.onTermination = newValue }
    }

    init(
        portResolver: @escaping PortResolver,
        socketFactory: @escaping @MainActor (String, UInt16) -> any DebugAdapterSocketConnection = {
            NetworkDebugAdapterSocketConnection(host: $0, port: $1)
        }
    ) {
        transport = MacTCPDebugAdapterTransport(
            endpointResolver: { root in
                let port = try await portResolver(root)
                return DebugAdapterEndpoint(host: "127.0.0.1", port: Int(port))
            },
            // A cold JDT/project import is endpoint discovery, not a TCP
            // connect. Keep it bounded without applying the direct-host budget.
            limits: .init(startupMilliseconds: 120_000),
            socketFactory: { socketFactory($0.host, UInt16($0.port)) }
        )
    }

    func start(rootURL: URL) throws { try transport.start(rootURL: rootURL) }
    func send(_ data: Data) throws { try transport.send(data) }
    func stop() { transport.stop() }
    func finishSendingAndStop() { transport.finishSendingAndStop() }
}
