import Foundation

/// Settings required to launch one locally installed ACP agent for a workspace.
///
/// Phase one signs in only with a user-supplied API key through the agent's
/// custom gateway; account logins offered by the agent are never used.
public struct AgentLaunchConfiguration: Equatable, Sendable {
    public let command: String
    public let arguments: [String]
    public let workspaceURL: URL
    /// Responses API endpoint of the selected AI provider.
    public let gatewayBaseURL: String
    public let apiKey: String
    public let providerName: String
    public let allowsInsecureHTTP: Bool

    public init(
        command: String,
        arguments: [String],
        workspaceURL: URL,
        gatewayBaseURL: String,
        apiKey: String,
        providerName: String,
        allowsInsecureHTTP: Bool
    ) {
        self.command = command
        self.arguments = arguments
        self.workspaceURL = workspaceURL
        self.gatewayBaseURL = gatewayBaseURL
        self.apiKey = apiKey
        self.providerName = providerName
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}

/// One platform-owned ACP connection. Closing it must release the whole
/// agent process tree; commands and events use the JSON shapes fixed by
/// `shared/fixtures/agent/acp-events-v1.json`.
@MainActor
public protocol AgentConnection: AnyObject {
    func send(commandJSON: String) throws
    func close() async
}

/// Starts a native connection only after the optional Agent module is activated.
@MainActor
public protocol AgentConversationTransport {
    func open(
        configuration: AgentLaunchConfiguration,
        onEvent: @escaping @Sendable (String) -> Void
    ) throws -> any AgentConnection
}
