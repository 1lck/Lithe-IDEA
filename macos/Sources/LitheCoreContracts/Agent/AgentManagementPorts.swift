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

/// The user's own agent CLI that an adapter drives, e.g. the Codex CLI.
public struct AgentCliStatus: Decodable, Equatable, Sendable {
    public let name: String
    public let command: String
    public let minimumVersion: String
    public let installHint: String
    /// Package used when installing a missing CLI or updating a verified npm installation.
    public let package: String
    public let detected: AgentRuntimeTool?
    public let installation: AgentCliInstallation?

    public init(name: String, command: String, minimumVersion: String, installHint: String, package: String = "", detected: AgentRuntimeTool?, installation: AgentCliInstallation? = nil) {
        self.name = name
        self.command = command
        self.minimumVersion = minimumVersion
        self.installHint = installHint
        self.package = package
        self.detected = detected
        self.installation = installation
    }
}

/// Provenance and safe update availability reported by the native host.
public struct AgentCliInstallation: Decodable, Equatable, Sendable {
    public enum Source: String, Decodable, Sendable { case npm, homebrew, native, missing, unknown }
    public let source: Source
    public let canUpdate: Bool
    /// Display only; the host resolves the real command again when updating.
    public let updateHint: String
    public init(source: Source, canUpdate: Bool, updateHint: String) {
        self.source = source
        self.canUpdate = canUpdate
        self.updateHint = updateHint
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
    /// The user's CLI the adapter runs; `nil` when the adapter is self-contained.
    public let cli: AgentCliStatus?
    /// Reasons the adapter cannot be installed or started now.
    public let issues: [String]

    public init(
        id: String, name: String, description: String, package: String, version: String,
        installedVersion: String?, protocol: String, minimumNodeMajor: Int, verified: Bool,
        cli: AgentCliStatus? = nil, issues: [String]
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
        self.cli = cli
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

/// Numbers-only npm progress; total package bytes are unknown until npm finishes.
public struct AgentInstallProgress: Decodable, Equatable, Sendable {
    public enum Stage: String, Decodable, Sendable { case preparing, downloading, installing, updating }
    public let stage: Stage
    public let downloadedBytes: UInt64
    public let bytesPerSecond: UInt64
    public let elapsedMilliseconds: UInt64
    public let idleMilliseconds: UInt64

    public init(stage: Stage, downloadedBytes: UInt64, bytesPerSecond: UInt64,
                elapsedMilliseconds: UInt64, idleMilliseconds: UInt64) {
        self.stage = stage
        self.downloadedBytes = downloadedBytes
        self.bytesPerSecond = bytesPerSecond
        self.elapsedMilliseconds = elapsedMilliseconds
        self.idleMilliseconds = idleMilliseconds
    }
}

/// Detects the user's runtime and installs ACP adapters with the user's npm.
/// Node.js remains user-managed; CLI updates follow their verified installation owners.
public protocol AgentManagementService: Sendable {
    func status(dataDirectory: URL) async throws -> AgentManagementStatus
    /// Installs the pinned adapter version; returns the installed version.
    func install(agentID: String, dataDirectory: URL) async throws -> String
    func uninstall(agentID: String, dataDirectory: URL) async throws
    /// Installs or updates the agent's own CLI through its installation manager; returns
    /// the CLI version found afterwards.
    func installCli(agentID: String, dataDirectory: URL) async throws -> String
    func install(agentID: String, dataDirectory: URL,
                 onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> String
    func installCli(agentID: String, dataDirectory: URL,
                    onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> String
}

public extension AgentManagementService {
    func install(agentID: String, dataDirectory: URL,
                 onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> String {
        try await install(agentID: agentID, dataDirectory: dataDirectory)
    }
    func installCli(agentID: String, dataDirectory: URL,
                    onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> String {
        try await installCli(agentID: agentID, dataDirectory: dataDirectory)
    }
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

    public func installCli(agentID: String, dataDirectory: URL) async throws -> String {
        throw CocoaError(.featureUnsupported)
    }
}
