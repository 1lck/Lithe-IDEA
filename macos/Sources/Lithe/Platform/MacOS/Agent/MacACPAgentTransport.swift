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
            "authentication": configuration.authentication.rawValue,
            "observeModelCalls": configuration.observesModelCalls,
            "observeSubagents": true
        ]
        // Marks the Agent's process tree so its tasks can be confirmed before
        // they are ended; see MacAgentProcessRegistry.
        let processScope = UUID().uuidString
        configurationJSON["processScope"] = processScope
        if configuration.authentication == .apiKey {
            configurationJSON["provider"] = [
                "protocol": configuration.providerProtocol,
                "baseUrl": configuration.providerEndpoint,
                "apiKey": configuration.apiKey,
                "name": configuration.providerName,
                "model": configuration.model,
                "allowInsecureHttp": configuration.allowsInsecureHTTP
            ]
        }
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
        let connection = MacACPAgentConnection(handle: handle, context: context, processScope: processScope)
        let commandName = URL(fileURLWithPath: configuration.command).lastPathComponent
        let agentName = configuration.agentID ?? (commandName.isEmpty ? "Agent" : commandName)
        MacAgentProcessRegistry.application.register(
            scope: processScope,
            agentName: agentName,
            workspace: configuration.workspaceURL.path
        ) { [weak connection] processIDs in
            connection?.preserve(processIDs)
        }
        return connection
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
    private let processScope: String

    init(handle: UnsafeMutableRawPointer, context: UnsafeMutableRawPointer, processScope: String) {
        self.handle = handle
        self.context = context
        self.processScope = processScope
    }

    func send(commandJSON: String) throws {
        if Self.isPrompt(commandJSON) {
            MacAgentProcessRegistry.application.noteFirstPrompt(scope: processScope)
        }
        guard let handle, commandJSON.withCString({ lithe_bridge_agent_send_json(handle, $0) }) == 1 else {
            throw MacACPAgentError.rejected
        }
    }

    /// Closing blocks until the agent tree exits (bounded by the host), so it
    /// runs off the main thread.
    func close() async {
        guard handle != nil else { return }
        await MacAgentProcessRegistry.application.prepareClose(scope: processScope)
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

    /// Keeps these processes alive when the connection closes.
    func preserve(_ processIDs: [pid_t]) {
        guard !processIDs.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [
                  "kind": "preserveProcesses",
                  "processIds": processIDs.map(Int.init)
              ]) else { return }
        try? send(commandJSON: String(decoding: data, as: UTF8.self))
    }

    private static func isPrompt(_ commandJSON: String) -> Bool {
        guard let data = commandJSON.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return command["kind"] as? String == "prompt"
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
