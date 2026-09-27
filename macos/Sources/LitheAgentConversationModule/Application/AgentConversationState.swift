import Foundation

/// One entry of the agent-owned conversation history for the workspace.
public struct AgentSessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String?
    public var updatedAt: String?

    public init(id: String, title: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public struct AgentConversationMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, agent, tool }
    public enum ToolStatus: String, Equatable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
        /// The connection or turn ended without a final tool status.
        case interrupted
    }

    public let id: String
    public let role: Role
    public var text: String
    public var toolStatus: ToolStatus?
    public var toolDetails = AgentToolDetails()

    public init(id: String = UUID().uuidString, role: Role, text: String, toolStatus: ToolStatus? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.toolStatus = toolStatus
    }
}

public struct AgentPermissionChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public var kind: String?
}

public struct AgentPermissionPrompt: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let choices: [AgentPermissionChoice]
    public var details = AgentToolDetails()
}

/// Display state of one conversation session.
public struct AgentConversation: Equatable, Sendable {
    public var messages: [AgentConversationMessage] = []
    public var isResponding = false
    public var isLoading = false
    public var isCancelling = false
    public var configOptions: [AgentSessionConfigOption] = []
    public var pendingConfigToken: String?
    public var configurationError: String?
    /// A new process must load this session before prompting it again.
    public var isAttached = false
    var pendingPermissions: [AgentPermissionPrompt] = []
    public var permission: AgentPermissionPrompt? { pendingPermissions.first }
    public var errorMessage: String?

    public init() {}

    mutating func enqueuePermission(_ prompt: AgentPermissionPrompt) {
        if let index = pendingPermissions.firstIndex(where: { $0.id == prompt.id }) {
            pendingPermissions[index] = prompt
        } else {
            pendingPermissions.append(prompt)
        }
    }

    mutating func interruptPendingTools() {
        for index in messages.indices where messages[index].role == .tool {
            if messages[index].toolStatus == .pending || messages[index].toolStatus == .inProgress {
                messages[index].toolStatus = .interrupted
            }
        }
    }
}
