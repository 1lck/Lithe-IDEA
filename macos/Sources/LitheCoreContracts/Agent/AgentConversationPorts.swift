import Foundation

/// Settings required to launch one ACP agent for a workspace.
///
/// Phase one signs in only with a user-supplied API key; account logins
/// offered by the agent are never used.
public struct AgentLaunchConfiguration: Equatable, Sendable {
    /// ACP registry id of a Lithe-installed adapter, or `nil` for `command`.
    public let agentID: String?
    public let command: String
    public let arguments: [String]
    public let workspaceURL: URL
    /// Directory holding Lithe-managed adapter installs.
    public let dataDirectory: URL
    /// Provider protocol raw value, matching `CommitMessageAPIProtocol`.
    public let providerProtocol: String
    public let providerEndpoint: String
    public let apiKey: String
    public let providerName: String
    /// Empty keeps the agent's default model.
    public let model: String
    public let allowsInsecureHTTP: Bool

    public init(
        agentID: String?,
        command: String,
        arguments: [String],
        workspaceURL: URL,
        dataDirectory: URL,
        providerProtocol: String,
        providerEndpoint: String,
        apiKey: String,
        providerName: String,
        model: String,
        allowsInsecureHTTP: Bool
    ) {
        self.agentID = agentID
        self.command = command
        self.arguments = arguments
        self.workspaceURL = workspaceURL
        self.dataDirectory = dataDirectory
        self.providerProtocol = providerProtocol
        self.providerEndpoint = providerEndpoint
        self.apiKey = apiKey
        self.providerName = providerName
        self.model = model
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
