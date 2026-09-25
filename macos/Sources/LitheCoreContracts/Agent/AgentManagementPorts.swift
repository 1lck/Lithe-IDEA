import Foundation

/// A tool found on the search path agents are launched with.
public struct AgentRuntimeTool: Decodable, Equatable, Sendable {
    public let version: String
    public let path: String

    public init(version: String, path: String) {
        self.version = version
        self.path = path
    }
}

/// User-installed Node.js and npm as seen by agent installs and launches.
public struct AgentRuntimeEnvironment: Decodable, Equatable, Sendable {
    public let node: AgentRuntimeTool?
    public let npm: AgentRuntimeTool?
    /// False when the login shell reported no `PATH` and only the app's was searched.
    public let usedLoginShell: Bool

    public init(node: AgentRuntimeTool?, npm: AgentRuntimeTool?, usedLoginShell: Bool) {
        self.node = node
        self.npm = npm
        self.usedLoginShell = usedLoginShell
    }
}

/// One supported ACP agent and its Lithe-managed adapter install.
public struct AgentCatalogStatus: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let package: String
    /// Version Lithe installs.
    public let version: String
    public let installedVersion: String?
    /// Provider protocol raw value, matching `CommitMessageAPIProtocol`.
    public let `protocol`: String
    public let minimumNodeMajor: Int
    public let verified: Bool
    /// Reasons the adapter cannot be installed or started now.
    public let issues: [String]

    public init(
        id: String, name: String, description: String, package: String, version: String,
        installedVersion: String?, protocol: String, minimumNodeMajor: Int, verified: Bool, issues: [String]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.package = package
        self.version = version
        self.installedVersion = installedVersion
        self.protocol = `protocol`
        self.minimumNodeMajor = minimumNodeMajor
        self.verified = verified
        self.issues = issues
    }

    public var isInstalled: Bool { installedVersion != nil }
    public var needsUpdate: Bool { installedVersion.map { $0 != version } ?? false }
}

/// Result of `agent.status`, fixed by `shared/fixtures/agent/agent-management-v1.json`.
public struct AgentManagementStatus: Decodable, Equatable, Sendable {
    public let environment: AgentRuntimeEnvironment
    public let agents: [AgentCatalogStatus]

    public init(environment: AgentRuntimeEnvironment, agents: [AgentCatalogStatus]) {
        self.environment = environment
        self.agents = agents
    }
}

/// Detects the user's runtime and installs ACP adapters with the user's npm.
/// Lithe never installs Node.js or the agents' own command-line tools.
public protocol AgentManagementService: Sendable {
    func status(dataDirectory: URL) async throws -> AgentManagementStatus
    /// Installs the pinned adapter version; returns the installed version.
    func install(agentID: String, dataDirectory: URL) async throws -> String
    func uninstall(agentID: String, dataDirectory: URL) async throws
}

/// Used where no platform adapter is composed, such as focused tests.
public struct UnavailableAgentManagementService: AgentManagementService {
    public init() {}

    public func status(dataDirectory: URL) async throws -> AgentManagementStatus {
        throw CocoaError(.featureUnsupported)
    }

    public func install(agentID: String, dataDirectory: URL) async throws -> String {
        throw CocoaError(.featureUnsupported)
    }

    public func uninstall(agentID: String, dataDirectory: URL) async throws {
        throw CocoaError(.featureUnsupported)
    }
}
