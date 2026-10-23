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
    func readShared() async throws -> SharedInstructionLibrary
    func saveShared(content: String, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary
    func setSharedEnabled(_ enabled: Bool, agent: AgentInstructionKind, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary
}

public struct UnavailableAgentInstructionsService: AgentInstructionsService {
    public init() {}
    public func read(agent: AgentInstructionKind) async throws -> AgentInstructionFile { throw CocoaError(.featureUnsupported) }
    public func save(file: AgentInstructionFile, content: String) async throws -> AgentInstructionFile { throw CocoaError(.featureUnsupported) }
}

/// Native snapshots and per-target failures keep partial synchronization explicit.
public struct SharedInstructionAgent: Decodable, Sendable {
    public let agentId: String
    public let file: AgentInstructionFile?
    public let enabled: Bool?
    public let needsSync: Bool
    public let ownLineCount: Int
    public let issue: String?
    public init(agentId: String, file: AgentInstructionFile?, enabled: Bool?, needsSync: Bool,
                ownLineCount: Int, issue: String?) {
        self.agentId = agentId; self.file = file; self.enabled = enabled; self.needsSync = needsSync
        self.ownLineCount = ownLineCount; self.issue = issue
    }
}

public struct SharedInstructionLibrary: Decodable, Sendable {
    public let file: AgentInstructionFile
    public let agents: [SharedInstructionAgent]
    public init(file: AgentInstructionFile, agents: [SharedInstructionAgent]) { self.file = file; self.agents = agents }
}

public extension AgentInstructionsService {
    func readShared() async throws -> SharedInstructionLibrary { throw CocoaError(.featureUnsupported) }
    func saveShared(content: String, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary { throw CocoaError(.featureUnsupported) }
    func setSharedEnabled(_ enabled: Bool, agent: AgentInstructionKind, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary { throw CocoaError(.featureUnsupported) }
}
