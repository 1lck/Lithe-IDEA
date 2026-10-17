import Foundation

/// Agent whose MCP configuration Lithe can discover and manage.
enum McpAgent: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode = "claude"

    var id: String { rawValue }

    /// Display name shown in the library and per-Agent toggles.
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    /// Value Core expects in `source`.
    var sourceName: String { rawValue }
}

/// Whether a configuration file is user-wide or belongs to one project.
enum McpConfigurationScope: String, Sendable {
    case global
    case project
}

/// One Agent configuration file Lithe reads or writes.
struct McpConfigurationFile: Hashable, Sendable {
    let agent: McpAgent
    let scope: McpConfigurationScope
    let url: URL
    /// Absolute project path for project-scoped Claude entries; `nil` otherwise.
    let projectPath: String?
}

/// One environment variable or HTTP header entry.
struct McpKeyValue: Codable, Hashable, Sendable {
    var key: String
    var value: String
}

/// Transport used to start or reach an MCP server.
enum McpTransport: String, Codable, CaseIterable, Sendable {
    case stdio
    case http
    case sse

    var title: String {
        switch self {
        case .stdio: "Command"
        case .http: "HTTP"
        case .sse: "SSE"
        }
    }
}

/// Normalized server definition shared by discovery, editing and Core planning.
struct McpServerDefinition: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var transport: McpTransport
    var command: String?
    var args: [String]
    var env: [McpKeyValue]
    var url: String?
    var headers: [McpKeyValue]
    /// Identity hash produced by Core; empty for drafts that have not been saved.
    var definitionHash: String

    /// Library identity: the same name with a different definition is a
    /// separate row so two agents never silently share an unrelated server.
    var id: String { "\(name)#\(definitionHash)" }

    init(
        name: String,
        transport: McpTransport = .stdio,
        command: String? = nil,
        args: [String] = [],
        env: [McpKeyValue] = [],
        url: String? = nil,
        headers: [McpKeyValue] = [],
        definitionHash: String = ""
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.definitionHash = definitionHash
    }

    private enum CodingKeys: String, CodingKey {
        case name, transport, command, args, env, url, headers, definitionHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decodeIfPresent(McpTransport.self, forKey: .transport) ?? .stdio
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([McpKeyValue].self, forKey: .env) ?? []
        url = try container.decodeIfPresent(String.self, forKey: .url)
        headers = try container.decodeIfPresent([McpKeyValue].self, forKey: .headers) ?? []
        definitionHash = try container.decodeIfPresent(String.self, forKey: .definitionHash) ?? ""
    }
}

/// Ledger entry recording that Lithe wrote a name at a known definition.
struct McpOwnedEntry: Codable, Hashable, Sendable {
    let name: String
    let definitionHash: String
}

/// One `set` or `remove` plan request sent to Core.
struct McpWriteRequest: Encodable, Sendable {
    let source: String
    let scope: String
    let projectPath: String?
    let content: String?
    let operation: String
    let server: McpServerDefinition?
    let name: String?
    let owned: [McpOwnedEntry]
}

/// Core's plan: the next file text plus whether anything changed.
struct McpWritePlan: Decodable, Sendable {
    let content: String
    let changed: Bool
    let action: String
    /// `ownedByUser` or `externallyModified` when the entry must not be touched.
    let conflict: String?
    /// Identity hash Core derived from the definition it planned, so the
    /// ledger records the hash of the bytes that actually reached the file.
    let definitionHash: String?
}

/// Receipt for a completed write, including where the previous bytes were kept.
struct McpWriteReceipt: Sendable {
    let backupURL: URL?
}

enum McpConfigurationError: LocalizedError, Equatable {
    case unavailable
    case unreadable(String)
    case tooLarge
    case changedOnDisk
    case notWritable(String)
    case core(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "MCP configuration management is unavailable.")
        case .unreadable(let path):
            String(format: String(localized: "Could not read %@."), path)
        case .tooLarge:
            String(localized: "This configuration is larger than 1 MiB and is not edited by Lithe.")
        case .changedOnDisk:
            String(localized: "The configuration changed on disk. Refresh and try again.")
        case .notWritable(let path):
            String(format: String(localized: "Could not write %@."), path)
        case .core(let message):
            message
        }
    }
}

/// Platform-owned file access plus Core-backed parsing and write planning.
@MainActor
protocol McpConfigurationStore {
    /// Files Lithe manages, including project-scoped files when a workspace is open.
    func configurationFiles(workspace: URL?) -> [McpConfigurationFile]
    /// Returns `nil` when the file does not exist yet.
    func read(_ file: McpConfigurationFile) throws -> String?
    /// Backs up existing bytes and replaces the file atomically.
    func write(_ content: String, to file: McpConfigurationFile) throws -> McpWriteReceipt
    /// Parses one file into normalized definitions, without echoing secrets.
    func parse(_ file: McpConfigurationFile, content: String) throws -> [McpServerDefinition]
    /// Plans a set or remove operation, enforcing the ownership ledger.
    func planWrite(_ request: McpWriteRequest, for file: McpConfigurationFile) throws -> McpWritePlan
    /// Adds a Lithe-created project file to Git's local exclude list so it does
    /// not appear as an untracked change. No-op outside a Git worktree.
    func excludeFromVersionControl(_ relativePath: String, workspace: URL) throws
}

/// Placeholder used before the platform graph is composed and in tests that do
/// not exercise MCP management.
struct UnavailableMcpConfigurationStore: McpConfigurationStore {
    func configurationFiles(workspace: URL?) -> [McpConfigurationFile] { [] }
    func read(_ file: McpConfigurationFile) throws -> String? { throw McpConfigurationError.unavailable }
    func write(_ content: String, to file: McpConfigurationFile) throws -> McpWriteReceipt {
        throw McpConfigurationError.unavailable
    }

    func parse(_ file: McpConfigurationFile, content: String) throws -> [McpServerDefinition] {
        throw McpConfigurationError.unavailable
    }

    func planWrite(_ request: McpWriteRequest, for file: McpConfigurationFile) throws -> McpWritePlan {
        throw McpConfigurationError.unavailable
    }

    func excludeFromVersionControl(_ relativePath: String, workspace: URL) throws {
        throw McpConfigurationError.unavailable
    }
}
