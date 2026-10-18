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
    /// Full source entry version, including Agent-specific fields absent from the editor.
    var sourceHash: String? = nil

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
        case name, transport, command, args, env, url, headers, definitionHash, sourceHash
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
        sourceHash = try container.decodeIfPresent(String.self, forKey: .sourceHash)
    }
}

/// Ledger entry recording that Lithe wrote a complete source entry.
struct McpOwnedEntry: Codable, Hashable, Sendable {
    let name: String
    let definitionHash: String
    /// Missing in legacy records, which must be adopted again before automatic writes.
    let sourceHash: String?

    init(name: String, definitionHash: String, sourceHash: String? = nil) {
        self.name = name
        self.definitionHash = definitionHash
        self.sourceHash = sourceHash
    }
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
    /// Existing name a `set` renames from; Core copies the old entry before
    /// applying the new definition so unmodeled fields survive.
    let previousName: String?
    let owned: [McpOwnedEntry]
    /// Full source version shown when editing; independent of the latest ledger.
    var expectedHash: String? = nil
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
    /// Complete source version derived from the planned output, not the draft.
    let sourceHash: String?
}

/// One compare-and-replace operation in an all-or-rollback batch.
struct McpConfigurationChange: Sendable {
    let file: McpConfigurationFile
    let source: String?
    let content: String
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
    case rollbackFailed(String)
    case notWritable(String)
    case retainedCopy(destination: String, retained: String)
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
        case .rollbackFailed(let paths):
            String(format: String(localized: "Some MCP configuration files could not be restored: %@. Refresh and check these files before retrying."), paths)
        case .notWritable(let path):
            String(format: String(localized: "Could not write %@."), path)
        case .retainedCopy(let destination, let retained):
            String(
                format: String(localized: "Could not write %@. The previous contents were kept in %@."),
                destination,
                retained
            )
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
    /// Backs up existing bytes and replaces the file atomically. The platform
    /// storage exchanges the destination with the prepared bytes, verifies the
    /// displaced snapshot and rolls the exchange back when another process
    /// saved after planning (including during the backup), so that save is
    /// preserved rather than overwritten.
    ///
    /// `expected` is the exact text the write was planned from; `nil` means the
    /// file must not exist yet. When the file changed after planning (another
    /// Agent, editor or Lithe instance saved it), the write is refused with
    /// `changedOnDisk` instead of overwriting the newer configuration.
    func write(
        _ content: String, to file: McpConfigurationFile, replacing expected: String?
    ) throws -> McpWriteReceipt
    /// Restores the original snapshot only while the file still contains this
    /// batch's output. A `nil` snapshot conditionally removes a file created by
    /// the batch, keeping any newer bytes another process wrote.
    func restore(_ change: McpConfigurationChange) throws
    /// Parses one file into normalized definitions, without echoing secrets.
    func parse(_ file: McpConfigurationFile, content: String) throws -> [McpServerDefinition]
    /// Plans a set or remove operation, enforcing the ownership ledger.
    func planWrite(_ request: McpWriteRequest, for file: McpConfigurationFile) throws -> McpWritePlan
    /// Adds a Lithe-created project file to Git's local exclude list so it does
    /// not appear as an untracked change. No-op outside a Git worktree.
    func excludeFromVersionControl(_ relativePath: String, workspace: URL) throws
}

extension McpConfigurationStore {
    /// Validates every snapshot first and unwinds completed writes in reverse
    /// order on failure. Callers publish ownership only after this returns.
    /// External edits during rollback are preserved and reported by path.
    func writeBatch(_ changes: [McpConfigurationChange]) throws -> [McpWriteReceipt] {
        for change in changes {
            guard try read(change.file) == change.source else {
                throw McpConfigurationError.changedOnDisk
            }
        }
        var completed: [McpConfigurationChange] = []
        var receipts: [McpWriteReceipt] = []
        do {
            for change in changes {
                receipts.append(try write(change.content, to: change.file, replacing: change.source))
                completed.append(change)
            }
        } catch {
            // If the failed write already kept a recovery copy, its location
            // must survive the rollback aggregation; otherwise a second
            // failure would replace the only pointer to that copy.
            let writeFailureDetail: String? = {
                guard let error = error as? McpConfigurationError,
                      case .retainedCopy = error else { return nil }
                return error.localizedDescription
            }()
            var unrestored: [String] = []
            for change in completed.reversed() {
                do {
                    try restore(change)
                } catch let retained as McpConfigurationError {
                    if case .retainedCopy = retained {
                        // The hidden recovery file is the only copy of the
                        // newest external save; keep its path in the message.
                        unrestored.append(
                            "\(change.file.url.path): \(retained.localizedDescription)"
                        )
                    } else {
                        unrestored.append(change.file.url.path)
                    }
                } catch {
                    unrestored.append(change.file.url.path)
                }
            }
            if !unrestored.isEmpty {
                var details = unrestored
                if let writeFailureDetail { details.insert(writeFailureDetail, at: 0) }
                throw McpConfigurationError.rollbackFailed(details.joined(separator: ", "))
            }
            throw error
        }
        return receipts
    }
}

/// Placeholder used before the platform graph is composed and in tests that do
/// not exercise MCP management.
struct UnavailableMcpConfigurationStore: McpConfigurationStore {
    func configurationFiles(workspace: URL?) -> [McpConfigurationFile] { [] }
    func read(_ file: McpConfigurationFile) throws -> String? { throw McpConfigurationError.unavailable }
    func write(
        _ content: String, to file: McpConfigurationFile, replacing expected: String?
    ) throws -> McpWriteReceipt {
        throw McpConfigurationError.unavailable
    }

    func restore(_ change: McpConfigurationChange) throws {
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
