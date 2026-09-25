import Foundation
import LitheCoreContracts
import LitheRustCore

@MainActor
final class MacACPAgentTransport: AgentConversationTransport {
    func open(
        configuration: AgentLaunchConfiguration,
        onEvent: @escaping @Sendable (String) -> Void
    ) throws -> any AgentConversationSession {
        let configurationJSON: [String: Any] = [
            "command": configuration.command,
            "args": configuration.arguments,
            "cwd": configuration.workspaceURL.path
        ]
        let data = try JSONSerialization.data(withJSONObject: configurationJSON)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MacACPAgentError.invalidConfiguration
        }
        let callback = AgentEventCallback(onEvent: onEvent)
        let context = Unmanaged.passRetained(callback).toOpaque()
        let handle = json.withCString { lithe_bridge_agent_open_json($0, macACPEventCallback, context) }
        guard let handle else {
            Unmanaged<AgentEventCallback>.fromOpaque(context).release()
            throw MacACPAgentError.unavailable
        }
        return MacACPAgentSession(handle: handle, context: context)
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
private final class MacACPAgentSession: AgentConversationSession {
    private var handle: UnsafeMutableRawPointer?
    private var context: UnsafeMutableRawPointer?

    init(handle: UnsafeMutableRawPointer, context: UnsafeMutableRawPointer) {
        self.handle = handle
        self.context = context
    }

    func send(_ prompt: String) throws {
        guard let handle, prompt.withCString({ lithe_bridge_agent_prompt(handle, $0) }) == 1 else {
            throw MacACPAgentError.stopped
        }
    }

    func cancel() {
        guard let handle else { return }
        _ = lithe_bridge_agent_cancel(handle)
    }

    func answerPermission(requestID: String, optionID: String?) {
        guard let handle else { return }
        requestID.withCString { request in
            if let optionID {
                optionID.withCString { option in
                    _ = lithe_bridge_agent_permission(handle, request, option)
                }
            } else {
                _ = lithe_bridge_agent_permission(handle, request, nil)
            }
        }
    }

    func stop() async {
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
        if let handle { lithe_bridge_agent_close(handle) }
        if let context { Unmanaged<AgentEventCallback>.fromOpaque(context).release() }
    }
}

private enum MacACPAgentError: LocalizedError {
    case invalidConfiguration
    case unavailable
    case stopped

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The Agent configuration is invalid."
        case .unavailable: "The ACP runtime is unavailable."
        case .stopped: "The Agent session has stopped."
        }
    }
}
