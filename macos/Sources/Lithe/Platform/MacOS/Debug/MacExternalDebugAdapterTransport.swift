import AppKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// User endpoints are not plugin declarations or debuggee attach arguments.
/// Validate before displaying consent, then let the same TCP lifecycle own only
/// the connection. Stopping it never kills the already running external server.
@MainActor
enum MacExternalDebugAdapterTransport {
    struct ValidatedEndpoint: Decodable {
        let host: String
        let port: Int
        let remote: Bool
    }

    static func make(
        endpoint: DebugAdapterEndpoint,
        validate: @MainActor (DebugAdapterEndpoint) throws -> ValidatedEndpoint,
        confirm: @MainActor (DebugAdapterEndpoint) -> Bool = confirmConnection,
        connectionProvider: (any DebugAdapterConnectionProviding)? = nil
    ) throws -> MacTCPDebugAdapterTransport {
        let checked = try validate(endpoint)
        let destination = DebugAdapterEndpoint(host: checked.host, port: checked.port)
        // Human approval is not a timed network operation. Do it before creating
        // the transport, so time spent reading the warning cannot expire startup.
        if checked.remote, !confirm(destination) {
            throw MacTCPDebugAdapterTransport.TransportError.connectionDeclined
        }
        return MacTCPDebugAdapterTransport(
            endpointResolver: { _ in destination },
            connectionProvider: connectionProvider
        )
    }

    private static func confirmConnection(_ endpoint: DebugAdapterEndpoint) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Connect to an external debug adapter?")
        let address = endpoint.host.contains(":") ? "[\(endpoint.host)]:\(endpoint.port)" : "\(endpoint.host):\(endpoint.port)"
        alert.informativeText = String(
            format: L10n.string("The debug adapter at %@ can access your debugging data. Plain TCP is not encrypted or authenticated. Connect only over a trusted network or a tunnel you configured."),
            address
        )
        // No remembered approval and no approval inferred from a loopback debuggee.
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.addButton(withTitle: L10n.string("Connect"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}
