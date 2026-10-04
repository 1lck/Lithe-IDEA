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
    /// `thought` holds the agent's streamed reasoning, kept apart from its reply.
    public enum Role: Equatable, Sendable { case user, agent, thought, tool }
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

/// Observable progress only: waiting does not imply internal model reasoning.
public enum AgentResponseStatus: Equatable, Sendable {
    case preparing, waiting, thinking, responding, runningTools, waitingForPermission, retrying, stopping
}

/// Display state of one conversation session.
public struct AgentConversation: Equatable, Sendable {
    public var messages: [AgentConversationMessage] = []
    public var contextUsage: AgentContextUsage?
    /// Latest complete plan from the agent; history replay restores it.
    public var plan: AgentPlan?
    /// Slash commands the agent currently advertises for this session.
    public var availableCommands: [AgentCommand] = []
    /// Only local review acknowledgements; the Agent's transcript is unchanged.
    public var reviewedFileChanges: [String: AgentFileChange] = [:]
    public var activeTurn: AgentTurnStatistics?
    var responsePhase: AgentResponseStatus = .waiting
    var retryTurnID: String?
    var previousRetryTurnID: String?
    public var responseStatus: AgentResponseStatus? {
        guard isResponding else { return nil }
        if isCancelling { return .stopping }
        if permission != nil { return .waitingForPermission }
        if responsePhase == .retrying { return .retrying }
        // History can contain unfinished tools; only this local turn is active.
        if let turn = activeTurn, let start = messages.lastIndex(where: { $0.id == turn.id }),
           messages[start...].contains(where: { $0.role == .tool && ($0.toolStatus == .pending || $0.toolStatus == .inProgress) }) {
            return .runningTools
        }
        return responsePhase
    }
    /// Local statistics survive tab switches and disconnects, but are not fabricated
    /// when the Agent replays history without timing or usage records.
    public var completedTurns: [AgentTurnStatistics] = []
    public var isResponding = false
    public var isLoading = false
    public var isCancelling = false
    public var configOptions: [AgentSessionConfigOption] = []
    public var pendingConfigToken: String?
    /// Choices for the next turn, separate from the Agent-confirmed configuration.
    var queuedConfigValues: [String: String] = [:]
    var pendingQueuedConfigID: String?
    public var displayConfigOptions: [AgentSessionConfigOption] {
        configOptions.map { option in
            var displayed = option
            if let value = queuedConfigValues[option.id], option.choices.contains(where: { $0.id == value }) {
                displayed.currentValue = value
            }
            return displayed
        }
    }
    public var configurationError: String?
    /// A new process must load this session before prompting it again.
    public var isAttached = false
    /// Only successful creation or loading establishes a complete history snapshot.
    /// Unlike attachment, this remains valid after disconnecting the process.
    public var hasCompleteHistory = false
    var pendingPermissions: [AgentPermissionPrompt] = []
    public var permission: AgentPermissionPrompt? { pendingPermissions.first }
    public var errorMessage: String?

    public init() {}

    mutating func finishTurn(at instant: ContinuousClock.Instant, usage: AgentTurnUsage? = nil) {
        if let retryTurnID { previousRetryTurnID = retryTurnID }
        retryTurnID = nil
        responsePhase = .waiting
        guard var turn = activeTurn else { return }
        turn.finish(at: instant, endingMessageID: messages.last?.id ?? turn.id, usage: usage)
        completedTurns.append(turn)
        activeTurn = nil
    }

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
