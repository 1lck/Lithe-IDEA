import Foundation
import LitheCoreContracts
import LitheRustCore

@MainActor
final class MacACPAgentTransport: AgentConversationTransport {
    func open(
        configuration: AgentLaunchConfiguration,
        onEvent: @escaping @Sendable (String) -> Void
    ) throws -> any AgentConnection {
        var configurationJSON: [String: Any] = [
            "args": configuration.arguments,
            "cwd": configuration.workspaceURL.path,
            "dataDirectory": configuration.dataDirectory.path,
            "provider": [
                "protocol": configuration.providerProtocol,
                "baseUrl": configuration.providerEndpoint,
                "apiKey": configuration.apiKey,
                "name": configuration.providerName,
                "model": configuration.model,
                "allowInsecureHttp": configuration.allowsInsecureHTTP
            ]
        ]
        if let agentID = configuration.agentID {
            configurationJSON["agentId"] = agentID
        } else {
            configurationJSON["command"] = configuration.command
        }
        let data = try JSONSerialization.data(withJSONObject: configurationJSON)
        let json = String(decoding: data, as: UTF8.self)
        let callback = AgentEventCallback(onEvent: onEvent)
        let context = Unmanaged.passRetained(callback).toOpaque()
        let handle = json.withCString { lithe_bridge_agent_open_json($0, macACPEventCallback, context) }
        guard let handle else {
            Unmanaged<AgentEventCallback>.fromOpaque(context).release()
            throw MacACPAgentError.invalidConfiguration
        }
        return MacACPAgentConnection(handle: handle, context: context)
    }
}

private final class AgentEventCallback: @unchecked Sendable {
    let onEvent: @Sendable (String) -> Void
    init(onEvent: @escaping @Sendable (String) -> Void) { self.onEvent = onEvent }
}

private func macACPEventCallback(_ event: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let event, let context else { return }
    let callback = Unmanaged<AgentEventCallback>.fromOpaque(context).takeUnretainedValue()
    callback.onEvent(String(cString: event))
}

@MainActor
private final class MacACPAgentConnection: AgentConnection {
    private var handle: UnsafeMutableRawPointer?
    private var context: UnsafeMutableRawPointer?

    init(handle: UnsafeMutableRawPointer, context: UnsafeMutableRawPointer) {
        self.handle = handle
        self.context = context
    }

    func send(commandJSON: String) throws {
        guard let handle, commandJSON.withCString({ lithe_bridge_agent_send_json(handle, $0) }) == 1 else {
            throw MacACPAgentError.rejected
        }
    }

    /// Closing blocks until the agent tree exits (bounded by the host), so it
    /// runs off the main thread.
    func close() async {
        guard let handle, let context else { return }
        self.handle = nil
        self.context = nil
        let handleAddress = Int(bitPattern: handle)
        let contextAddress = Int(bitPattern: context)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                lithe_bridge_agent_close(UnsafeMutableRawPointer(bitPattern: handleAddress))
                if let pointer = UnsafeMutableRawPointer(bitPattern: contextAddress) {
                    Unmanaged<AgentEventCallback>.fromOpaque(pointer).release()
                }
                continuation.resume()
            }
        }
    }

    deinit {
        // Normal paths call `close()`; this only guards an abandoned connection.
        guard let handle, let context else { return }
        let handleAddress = Int(bitPattern: handle)
        let contextAddress = Int(bitPattern: context)
        DispatchQueue.global(qos: .utility).async {
            lithe_bridge_agent_close(UnsafeMutableRawPointer(bitPattern: handleAddress))
            if let pointer = UnsafeMutableRawPointer(bitPattern: contextAddress) {
                Unmanaged<AgentEventCallback>.fromOpaque(pointer).release()
            }
        }
    }
}

private enum MacACPAgentError: LocalizedError {
    case invalidConfiguration
    case rejected

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The Agent configuration is invalid. Check the executable, API endpoint, and key."
        case .rejected: "The Agent did not accept the request. It may have stopped."
        }
    }
}
