import Foundation

public enum AgentInstructionKind: String, CaseIterable, Identifiable, Sendable {
    case codex = "codex-acp"
    case claude = "claude-acp"
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
}

/// Snapshot of the effective native user file. Revision/path guard a later save.
public struct AgentInstructionFile: Decodable, Equatable, Sendable {
    public let agentId: String
    public let path: String
    public let content: String
    public let exists: Bool
    public let revision: String

    public init(agentId: String, path: String, content: String, exists: Bool, revision: String) {
        self.agentId = agentId
        self.path = path
        self.content = content
        self.exists = exists
        self.revision = revision
    }
}

public protocol AgentInstructionsService: Sendable {
    func read(agent: AgentInstructionKind) async throws -> AgentInstructionFile
    func save(file: AgentInstructionFile, content: String) async throws -> AgentInstructionFile
}

public struct UnavailableAgentInstructionsService: AgentInstructionsService {
    public init() {}
    public func read(agent: AgentInstructionKind) async throws -> AgentInstructionFile { throw CocoaError(.featureUnsupported) }
    public func save(file: AgentInstructionFile, content: String) async throws -> AgentInstructionFile { throw CocoaError(.featureUnsupported) }
}
