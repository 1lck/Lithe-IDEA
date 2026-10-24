import Foundation

public enum AgentHookEvent: String, Codable, CaseIterable, Sendable {
    case turnEnd = "turn-end", afterTool = "after-tool", beforeTool = "before-tool"
    case prompt, sessionStart = "session-start"
    public var title: String {
        switch self {
        case .turnEnd: "When a turn ends"
        case .afterTool: "After a tool runs"
        case .beforeTool: "Before a tool runs"
        case .prompt: "When submitting a prompt"
        case .sessionStart: "When a session starts"
        }
    }
    public var supportsMatcher: Bool { self == .beforeTool || self == .afterTool }
}

public enum AgentHookMatcher: String, Codable, CaseIterable, Sendable {
    case all, shell, edit
    public var title: String {
        switch self { case .all: "All tools"; case .shell: "Shell commands"; case .edit: "File edits" }
    }
}

public struct AgentHook: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var event: AgentHookEvent
    public var matcher: AgentHookMatcher
    public var command: String
    public var timeoutSeconds: Int?
    public var agents: [String]
    public var enabled: Bool
    public var pendingRemoval: Bool

    public init(id: String = UUID().uuidString, name: String = "", description: String = "",
                event: AgentHookEvent = .turnEnd, matcher: AgentHookMatcher = .all, command: String = "",
                timeoutSeconds: Int? = nil, agents: [String] = ["codex-acp", "claude-acp"],
                enabled: Bool = true, pendingRemoval: Bool = false) {
        self.id = id; self.name = name; self.description = description; self.event = event
        self.matcher = matcher; self.command = command; self.timeoutSeconds = timeoutSeconds
        self.agents = agents; self.enabled = enabled; self.pendingRemoval = pendingRemoval
    }
}

public struct AgentHookFileGuard: Codable, Equatable, Sendable {
    public let agentId: String
    public let path: String
    public let revision: String
    public init(agentId: String, path: String, revision: String) {
        self.agentId = agentId; self.path = path; self.revision = revision
    }
}

public struct AgentHookTarget: Decodable, Equatable, Sendable {
    public let agentId: String
    public let file: AgentHookFileGuard?
    public let issue: String?
    public let disabled: Bool
    public init(agentId: String, file: AgentHookFileGuard?, issue: String?, disabled: Bool) {
        self.agentId = agentId; self.file = file; self.issue = issue; self.disabled = disabled
    }
}

/// Hook fields are flattened on the shared wire; actual native state is separate.
public struct AgentHookEntry: Decodable, Identifiable, Equatable, Sendable {
    public let hook: AgentHook
    public let configuredAgents: [String]
    public let needsSync: Bool
    public var id: String { hook.id }
    private enum CodingKeys: String, CodingKey { case configuredAgents, needsSync }
    public init(from decoder: Decoder) throws {
        hook = try AgentHook(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configuredAgents = try values.decode([String].self, forKey: .configuredAgents)
        needsSync = try values.decode(Bool.self, forKey: .needsSync)
    }
    public init(hook: AgentHook, configuredAgents: [String], needsSync: Bool) {
        self.hook = hook; self.configuredAgents = configuredAgents; self.needsSync = needsSync
    }
}

public struct AgentHookLibrary: Decodable, Equatable, Sendable {
    public let revision: String
    public let hooks: [AgentHookEntry]
    public let targets: [AgentHookTarget]
    public init(revision: String, hooks: [AgentHookEntry], targets: [AgentHookTarget]) {
        self.revision = revision; self.hooks = hooks; self.targets = targets
    }
}

public protocol AgentHooksService: Sendable {
    func load() async throws -> AgentHookLibrary
    func save(_ hook: AgentHook, library: AgentHookLibrary) async throws -> AgentHookLibrary
    func remove(id: String, library: AgentHookLibrary) async throws -> AgentHookLibrary
    func sync(library: AgentHookLibrary) async throws -> AgentHookLibrary
}

public struct UnavailableAgentHooksService: AgentHooksService {
    public init() {}
    public func load() async throws -> AgentHookLibrary { throw CocoaError(.featureUnsupported) }
    public func save(_ hook: AgentHook, library: AgentHookLibrary) async throws -> AgentHookLibrary { throw CocoaError(.featureUnsupported) }
    public func remove(id: String, library: AgentHookLibrary) async throws -> AgentHookLibrary { throw CocoaError(.featureUnsupported) }
    public func sync(library: AgentHookLibrary) async throws -> AgentHookLibrary { throw CocoaError(.featureUnsupported) }
}
