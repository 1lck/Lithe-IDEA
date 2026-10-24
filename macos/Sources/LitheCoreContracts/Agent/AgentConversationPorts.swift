import Foundation

/// The billing source explicitly selected for an Agent connection.
public enum AgentAuthentication: String, Codable, Equatable, Sendable {
    case apiKey
    case codexSubscription
    /// The user's signed-in Claude Code CLI pays. Lithe passes no key or route
    /// and never reads the CLI's credentials.
    case claudeSubscription

    public var isSubscription: Bool { self != .apiKey }

    /// The account subscription a built-in Agent can use, if any. Each
    /// subscription belongs to exactly one adapter.
    public static func subscription(for agentID: String) -> AgentAuthentication? {
        switch agentID {
        case "codex-acp": .codexSubscription
        case "claude-acp": .claudeSubscription
        default: nil
        }
    }
}

/// Settings required to launch one ACP agent for a workspace.
///
/// API providers and local Codex subscription accounts use distinct launch paths.
public struct AgentLaunchConfiguration: Equatable, Sendable {
    public let authentication: AgentAuthentication
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
    /// Route API-key provider traffic through the Host's loopback proxy to
    /// observe individual model calls. Subscription connections ignore it.
    public let observesModelCalls: Bool
    /// Configuration directory of the chosen subscription account, exported as
    /// `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. `nil` keeps the CLI's default
    /// account. It only holds the official CLI's own login; Lithe never reads it.
    public let accountDirectory: URL?

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
        allowsInsecureHTTP: Bool,
        authentication: AgentAuthentication = .apiKey,
        observesModelCalls: Bool = false,
        accountDirectory: URL? = nil
    ) {
        self.authentication = authentication
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
        self.observesModelCalls = observesModelCalls
        self.accountDirectory = accountDirectory
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
