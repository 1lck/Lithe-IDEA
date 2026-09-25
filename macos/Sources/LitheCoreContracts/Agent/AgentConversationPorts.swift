import Foundation

/// Settings required to launch one locally installed ACP agent.
public struct AgentLaunchConfiguration: Equatable, Sendable {
    public let command: String
    public let arguments: [String]
    public let workspaceURL: URL

    public init(command: String, arguments: [String], workspaceURL: URL) {
        self.command = command
        self.arguments = arguments
        self.workspaceURL = workspaceURL
    }
}

/// A platform-owned ACP session. Stopping it must release its entire process tree.
@MainActor
public protocol AgentConversationSession: AnyObject {
    func send(_ prompt: String) throws
    func cancel()
    func answerPermission(requestID: String, optionID: String?)
    func stop() async
}

/// Starts a native session only after the optional Agent module is activated.
@MainActor
public protocol AgentConversationTransport {
    func open(
        configuration: AgentLaunchConfiguration,
        onEvent: @escaping @Sendable (String) -> Void
    ) throws -> any AgentConversationSession
}
