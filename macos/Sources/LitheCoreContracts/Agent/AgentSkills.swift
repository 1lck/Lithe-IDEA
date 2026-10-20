import Foundation

/// Native discovery metadata. Claude enablement is scoped configured visibility,
/// not a claim about managed policy or an already connected session.
public struct AgentSkill: Decodable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let description: String
    public let path: String
    public let scope: String
    public let enabled: Bool?
    public let pluginId: String?

    public init(name: String, description: String, path: String, scope: String, enabled: Bool? = nil, pluginId: String? = nil) {
        self.name = name; self.description = description; self.path = path; self.scope = scope; self.enabled = enabled; self.pluginId = pluginId
    }
}

/// A deliberate write to native settings, addressed by discovered skill path.
public struct AgentSkillEnablement: Encodable, Sendable {
    public let action = "setEnabled"
    public let agentId: String
    public let workspace: String?
    public let scope: String
    public let source: String
    public let enabled: Bool

    public init(agentID: String, workspace: URL?, skill: AgentSkill, enabled: Bool) {
        agentId = agentID; self.workspace = workspace?.path; scope = skill.scope; source = skill.path; self.enabled = enabled
    }
}

public struct AgentSkillListing: Decodable, Equatable, Sendable {
    public let skills: [AgentSkill]
    /// "agent" for native discovery, "directory" for a partial file inventory.
    public let source: String
    public let issues: [String]
    public let directories: [String: String]

    public init(skills: [AgentSkill], source: String, issues: [String] = [], directories: [String: String] = [:]) {
        self.skills = skills; self.source = source; self.issues = issues; self.directories = directories
    }
}

/// Explicit write to the selected Agent's native user/project skill directory.
public struct AgentSkillWrite: Encodable, Sendable {
    public let action: String
    public let agentId: String
    public let workspace: String?
    public let scope: String
    public let name: String?
    public let description: String?
    public let instructions: String?
    public let source: String?

    public init(agentID: String, workspace: URL?, scope: String, name: String, description: String, instructions: String) {
        action = "create"; agentId = agentID; self.workspace = workspace?.path; self.scope = scope
        self.name = name; self.description = description; self.instructions = instructions; source = nil
    }

    public init(agentID: String, workspace: URL?, scope: String, source: URL) {
        action = "import"; agentId = agentID; self.workspace = workspace?.path; self.scope = scope
        name = nil; description = nil; instructions = nil; self.source = source.path
    }
}
