import Foundation

/// An upstream-announced child of the selected conversation, never inferred from
/// a shell command or a tool's display title. History and execution remain upstream.
public struct AgentSubagent: Identifiable, Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case running, completed, failed, cancelled, disconnected
    }

    public let id: String
    public let parentSessionID: String
    public var name: String
    public var task: String
    public var state: State
    /// Nesting is presentation only; IDs always retain their upstream identity.
    public let depth: Int

    public init(id: String, parentSessionID: String, name: String, task: String,
                state: State = .running, depth: Int = 0) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.name = name
        self.task = task
        self.state = state
        self.depth = depth
    }
}
