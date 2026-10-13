import Foundation

/// Lithe-owned presentation metadata; the Agent still owns the transcript.
public struct AgentHistoryMetadata: Codable, Equatable, Sendable {
    public var title: String?
    public var isFavorite: Bool
    /// Hides a row in Lithe without deleting the Agent's original session.
    public var isHidden: Bool

    public init(title: String? = nil, isFavorite: Bool = false, isHidden: Bool = false) {
        self.title = title
        self.isFavorite = isFavorite
        self.isHidden = isHidden
    }
}

/// Platform preferences, isolated by workspace and configured Agent identity.
@MainActor
public protocol AgentHistoryPersisting {
    func load(workspaceURL: URL, agentID: String) throws -> [String: AgentHistoryMetadata]
    func save(_ metadata: [String: AgentHistoryMetadata], workspaceURL: URL, agentID: String) throws
}

/// Native save dialog and file writing. A cancelled dialog returns nil.
@MainActor
public protocol AgentHistoryExporting {
    func chooseDestination() -> URL?
    func writeMarkdown(_ markdown: String, to url: URL) async throws
}
