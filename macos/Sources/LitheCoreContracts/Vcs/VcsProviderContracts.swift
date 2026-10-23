import Foundation
import LitheModuleAPI

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

// MARK: Declarations

/// A VCS provider a declarative plugin adds (`vcsProviders` capability).
/// Rust Core owns its root detection, launch plan, requests, and reply
/// validation; the host only needs to know which VCS it is and its name.
public struct DeclarativeVcsProvider: Equatable, Sendable {
    /// The VCS ID, such as `svn`, that roots and replies carry.
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    // MARK: Tool window

    /// Contribution visibility keys naming the provider a host-derived
    /// window or command belongs to.
    public static let pluginIDKey = "vcsProviderPluginID"
    public static let vcsKey = "vcsProviderID"

    /// The host's tool window for one provider. Plugin-declared UI ids
    /// cannot contain `:`, so this never collides with the plugin's own windows.
    public static func toolWindowID(pluginID: String, vcs: String) -> String {
        "\(pluginID).vcs-providers:\(vcs)"
    }

    /// The tool window and its toggle command, derived from the declaration
    /// like a build system's: every provider gets the same window, which
    /// sits next to the Git commit window and shares its version control
    /// icon (the `git` host icon), since a provider declares none.
    public func contributions(pluginID: String, order: Int) -> [ModuleContribution] {
        let windowID = Self.toolWindowID(pluginID: pluginID, vcs: id)
        let visibility = [Self.pluginIDKey: pluginID, Self.vcsKey: id]
        let icon = PluginUIIcon(host: "git")
        return [
            ModuleContribution(
                id: windowID, kind: .toolWindow, title: displayName, placement: .leftSidebar,
                order: 210 + order, actionID: windowID + ".toggle", rendererID: windowID,
                visibility: visibility, uiIcon: icon
            ),
            ModuleContribution(
                id: windowID + ".command", kind: .command, title: displayName, placement: .commandPalette,
                order: order, actionID: windowID + ".command",
                visibility: visibility.merging(["toolWindowID": windowID]) { _, new in new }, uiIcon: icon
            )
        ]
    }
}

/// An enabled plugin's VCS providers, as the host hands them to Rust Core.
package struct VcsProviderPluginSource: Equatable, Sendable {
    package let pluginID: String
    /// Normalized manifest from `plugins.declarative.validate`.
    package let manifest: Data
    /// Installed package directory, read-only, for `${pluginDir}`.
    package let packageURL: URL
    package let providers: [DeclarativeVcsProvider]

    package init(pluginID: String, manifest: Data, packageURL: URL, providers: [DeclarativeVcsProvider]) {
        self.pluginID = pluginID; self.manifest = manifest; self.packageURL = packageURL
        self.providers = providers
    }
}

/// The provider process of one VCS of one plugin in one workspace. Two
/// plugins, or two workspaces, never share a process.
package struct VcsProviderTarget: Hashable, Sendable {
    package let pluginID: String
    package let vcs: String
    package let manifest: Data
    package let packageURL: URL
    package let workspaceURL: URL

    package init(pluginID: String, vcs: String, manifest: Data, packageURL: URL, workspaceURL: URL) {
        self.pluginID = pluginID; self.vcs = vcs; self.manifest = manifest
        self.packageURL = packageURL; self.workspaceURL = workspaceURL.standardizedFileURL
    }
}

// MARK: Negotiation

/// Capabilities of protocol version 1. UI decisions read these only, never
/// the VCS ID.
package enum VcsCapability: String, CaseIterable, Sendable {
    case status, baseContent, checkin, rollback, history, fileHistory, annotate, update
    case push, staging, fileOperations, conflicts, cleanup
}

/// What a provider answered in `initialize`, as Core's `vcsProvider`
/// runtime event reports it.
public struct VcsProviderNegotiation: Equatable, Sendable, Decodable {
    public let vcs: String
    /// Capability ID to version; Core drops what it cannot validate.
    public let capabilities: [String: Int]

    public init(vcs: String, capabilities: [String: Int]) {
        self.vcs = vcs
        self.capabilities = capabilities
    }

    package func supports(_ capability: VcsCapability) -> Bool {
        capabilities[capability.rawValue] != nil
    }
}

// MARK: Detection

/// One provider `vcs.detectRoots` knows, the built-in Git included.
package struct VcsProviderDescriptor: Equatable, Sendable, Decodable {
    package struct Origin: Equatable, Sendable, Decodable {
        /// `builtIn` or `plugin`.
        package let kind: String
        package let pluginID: String?
    }

    package struct Tool: Equatable, Sendable, Decodable {
        package let commands: [String]
        package let validationArguments: [String]?
    }

    /// An entry directly inside a root that marks it, such as `.svn`.
    package struct Marker: Equatable, Sendable, Decodable {
        package let name: String
        /// `directory` or `file`.
        package let type: String
    }

    package let vcs: String
    package let displayName: String
    package let origin: Origin
    package let markers: [Marker]
    /// Root-relative files whose change means the status may be stale,
    /// such as `.svn/wc.db`. Absent for the built-in Git.
    package let metadataPaths: [String]?
    package let tool: Tool?
    package let mayUseNetwork: Bool?
}

/// A working-copy root. `id` is relative to the workspace (`""` is the
/// workspace itself, `..` an enclosing working copy); `path` is absolute.
package struct VcsRoot: Equatable, Hashable, Sendable, Decodable {
    package let id: String
    package let vcs: String
    package let path: String
    /// The user chose this VCS for an ambiguous directory.
    package let mapped: Bool

    package init(id: String, vcs: String, path: String, mapped: Bool = false) {
        self.id = id; self.vcs = vcs; self.path = path; self.mapped = mapped
    }
}

/// A directory with markers of several VCSs. Core never guesses; it stays
/// unowned until the user maps it.
package struct VcsAmbiguousDirectory: Equatable, Sendable, Decodable {
    package let id: String
    package let vcs: [String]
}

/// The user's choice for an ambiguous directory.
package struct VcsRootMapping: Equatable, Hashable, Sendable, Codable {
    package let id: String
    package let vcs: String

    package init(id: String, vcs: String) {
        self.id = id; self.vcs = vcs
    }
}

package struct VcsDetection: Equatable, Sendable, Decodable {
    package struct Rejected: Equatable, Sendable, Decodable {
        package struct Error: Equatable, Sendable, Decodable {
            package let code: String
            package let message: String
        }

        package let index: Int
        package let error: Error
    }

    package struct Conflict: Equatable, Sendable, Decodable {
        package let pluginID: String
        package let vcs: String
        package let by: String
    }

    package let providers: [VcsProviderDescriptor]
    package let roots: [VcsRoot]
    package let ambiguous: [VcsAmbiguousDirectory]
    package let unusedMappings: [VcsRootMapping]
    /// The directory budget ran out, so a root may be missing.
    package let truncated: Bool
    package let rejected: [Rejected]
    package let conflicts: [Conflict]
}

// MARK: Replies

package struct VcsRevision: Equatable, Hashable, Sendable, Decodable {
    package let id: String
    package let display: String
    /// `hash`, `number`, or `opaque`; presentation only.
    package let kind: String
}

package struct VcsHead: Equatable, Sendable, Decodable {
    package let revision: VcsRevision?
    package let branch: String?
    package let location: String?
}

package enum VcsChangeStatus: String, Equatable, Hashable, Sendable, Decodable {
    case modified, added, deleted, missing, renamed, copied, replaced, typeChanged
    case unversioned, ignored, conflicted, switched
}

/// One changed path, relative to its root.
package struct VcsChange: Equatable, Hashable, Sendable, Decodable {
    package let path: String
    package let oldPath: String?
    package let status: VcsChangeStatus
    /// `external`, `locked`, `lockedByOther`, `propertiesModified`,
    /// `submodule`, `treeConflict`; unknown flags never reach the host.
    package let flags: [String]

    package init(path: String, oldPath: String? = nil, status: VcsChangeStatus, flags: [String] = []) {
        self.path = path; self.oldPath = oldPath; self.status = status; self.flags = flags
    }

    package var hasTreeConflict: Bool { flags.contains("treeConflict") }
}

package struct VcsStatusSnapshot: Equatable, Sendable, Decodable {
    package let head: VcsHead
    package let changes: [VcsChange]
    /// The list is incomplete and must not be shown as complete.
    package let truncated: Bool
}

package struct VcsBaseContent: Equatable, Sendable, Decodable {
    /// Nil when the file has no base, or is binary.
    package let content: String?
    package let binary: Bool
}

package struct VcsHistoryEntry: Equatable, Sendable, Decodable, Identifiable {
    package let revision: VcsRevision
    package let author: String?
    package let date: String?
    package let message: String
    package let changes: [VcsChange]
    package let changesTruncated: Bool

    package var id: String { revision.id }
}

package struct VcsHistoryPage: Equatable, Sendable, Decodable {
    package let entries: [VcsHistoryEntry]
    package let nextCursor: String?
}

package struct VcsCheckinResult: Equatable, Sendable, Decodable {
    package let revision: VcsRevision?
}

package struct VcsUpdateResult: Equatable, Sendable, Decodable {
    package let revision: VcsRevision?
    package let conflicts: [String]
}

/// Replies of operations that return nothing.
package struct VcsEmptyResult: Equatable, Sendable, Decodable {}

// MARK: Operations

/// One operation of protocol version 1 with its arguments. The host names
/// operations, never methods; Core plans the request.
package enum VcsOperation: Equatable, Sendable {
    case status(includeIgnored: Bool)
    case baseContent(path: String)
    case history(cursor: String?, limit: Int?)
    case fileHistory(path: String, cursor: String?, limit: Int?)
    case checkin(paths: [String], message: String)
    case rollback(paths: [String])
    case update(revision: String?)
    case add(paths: [String])
    case delete(paths: [String])
    case move(from: String, to: String)
    case resolve(paths: [String])
    case cleanup

    package var name: String {
        switch self {
        case .status: "status"
        case .baseContent: "baseContent"
        case .history: "history"
        case .fileHistory: "fileHistory"
        case .checkin: "checkin"
        case .rollback: "rollback"
        case .update: "update"
        case .add, .delete, .move: "fileOperation"
        case .resolve: "resolve"
        case .cleanup: "cleanup"
        }
    }

    package var capability: VcsCapability {
        switch self {
        case .status: .status
        case .baseContent: .baseContent
        case .history: .history
        case .fileHistory: .fileHistory
        case .checkin: .checkin
        case .rollback: .rollback
        case .update: .update
        case .add, .delete, .move: .fileOperations
        case .resolve: .conflicts
        case .cleanup: .cleanup
        }
    }

    /// Whether the operation changes the working copy, so status must be
    /// read again after it.
    package var modifiesWorkingCopy: Bool {
        switch self {
        case .status, .baseContent, .history, .fileHistory: false
        default: true
        }
    }

    /// The arguments as `lsp.vcsRequest` and `vcs.decodeReply` take them.
    package var arguments: ToolingJSONValue {
        func paths(_ values: [String]) -> ToolingJSONValue { .array(values.map { .string($0) }) }
        func optional(_ value: String?) -> ToolingJSONValue { value.map { .string($0) } ?? .null }
        var members: [String: ToolingJSONValue] = [:]
        switch self {
        case .status(let includeIgnored):
            if includeIgnored { members["includeIgnored"] = .bool(true) }
        case .baseContent(let path):
            members["path"] = .string(path)
        case .history(let cursor, let limit):
            if let cursor { members["cursor"] = .string(cursor) }
            if let limit { members["limit"] = .integer(limit) }
        case .fileHistory(let path, let cursor, let limit):
            members["path"] = .string(path)
            if let cursor { members["cursor"] = .string(cursor) }
            if let limit { members["limit"] = .integer(limit) }
        case .checkin(let values, let message):
            members["paths"] = paths(values)
            members["message"] = .string(message)
        case .rollback(let values), .resolve(let values):
            members["paths"] = paths(values)
        case .update(let revision):
            if let revision { members["revision"] = optional(revision) }
        case .add(let values):
            members["kind"] = .string("add")
            members["paths"] = paths(values)
        case .delete(let values):
            members["kind"] = .string("delete")
            members["paths"] = paths(values)
        case .move(let from, let to):
            members["kind"] = .string("move")
            members["from"] = .string(from)
            members["to"] = .string(to)
        case .cleanup:
            break
        }
        return .object(members)
    }
}

/// A failed VCS request. `code` is a contract code such as `vcs.outOfDate`,
/// or `plugin.vcs.invalidOutput` when Core rejected the reply.
package struct VcsProviderFailure: LocalizedError, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code; self.message = message
    }

    package var errorDescription: String? { message }
}

// MARK: Ports

/// Rust Core's `vcs.*` commands. Implementations throw
/// `DeclarativePluginRejection` when Core cannot be reached and
/// `VcsProviderFailure` for a rejected reply.
package protocol VcsRootPlanning: Sendable {
    func detectRoots(
        workspaceURL: URL,
        manifests: [Data],
        mappings: [VcsRootMapping]
    ) throws -> VcsDetection
    /// The root ID owning each workspace-relative path, in request order.
    func owners(roots: [String], ambiguous: [String], paths: [String]) throws -> [String?]
    func decodeReply<Value: Decodable>(
        _ operation: VcsOperation,
        capabilities: [String: Int],
        reply: ToolingJSONValue,
        as type: Value.Type
    ) throws -> Value
}

/// A provider's reply with the negotiation of the session that sent it.
package struct VcsProviderReply: Sendable {
    package let value: ToolingJSONValue
    package let negotiation: VcsProviderNegotiation

    package init(value: ToolingJSONValue, negotiation: VcsProviderNegotiation) {
        self.value = value; self.negotiation = negotiation
    }
}

/// Provider processes. A request starts the target's process when none
/// runs; the reply is the provider's raw value, which the caller decodes
/// through `VcsRootPlanning.decodeReply`.
@MainActor
package protocol VcsProviderRequesting: AnyObject {
    /// The target's negotiation, starting its process when needed.
    func negotiation(for target: VcsProviderTarget) async throws -> VcsProviderNegotiation
    func send(
        _ operation: VcsOperation,
        root: String,
        to target: VcsProviderTarget,
        timeout: Duration
    ) async throws -> VcsProviderReply
    /// Stops every process whose target `keep` rejects.
    func retainProviders(_ keep: (VcsProviderTarget) -> Bool)
}
