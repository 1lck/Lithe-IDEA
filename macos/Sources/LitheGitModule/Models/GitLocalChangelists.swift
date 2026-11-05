import Foundation

/// Local UI metadata, independent of the Git index. Core owns membership and commit scope.
package struct GitLocalChangelist: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package var name: String
    package var displayName: String { id == GitLocalChangelists.defaultID ? "Default ChangeList" : name }
}

package struct GitChangelistIdentity: Hashable, Sendable {
    let root: String
    let path: String
    let original: String?
    let isCopy: Bool
    init(_ change: GitChange) {
        root = change.repositoryRoot.standardizedFileURL.path
        path = change.path
        original = change.originalPath
        isCopy = change.indexStatus == "C" || change.workTreeStatus == "C"
    }
}

package struct GitLocalChangelists: Codable, Equatable, Sendable {
    package init() {}
    package static let defaultID = "default"
    package var version = 1
    package var lists = [GitLocalChangelist(id: defaultID, name: "")]
    package var activeID = defaultID
    /// Repository/worktree root -> literal repository-relative path -> list ID.
    package var assignments: [String: [String: String]] = [:]
    /// Transient results are not part of persisted host metadata.
    var projectedMembership: [GitChangelistIdentity: String] = [:]
    private enum CodingKeys: String, CodingKey { case version, lists, activeID, assignments }

    /// The host checks its storage version; Core validates all semantic fields.
    package var isValid: Bool { version == 1 }

    package func listID(for change: GitChange) -> String {
        if let id = projectedMembership[GitChangelistIdentity(change)] { return id }
        // With no assignments every file is in Default. Otherwise a missing
        // projection is unavailable rather than permission to include a path.
        return assignments.isEmpty ? Self.defaultID : ""
    }

    func metadataEquals(_ other: Self) -> Bool {
        version == other.version && lists == other.lists && activeID == other.activeID && assignments == other.assignments
    }

    func withMembership(_ members: [String], for changes: [GitChange]) -> Self? {
        let ids = Set(lists.map(\.id))
        guard members.count == changes.count, members.allSatisfy({ ids.contains($0) }) else { return nil }
        var value = self
        value.projectedMembership.removeAll(keepingCapacity: true)
        for (change, member) in zip(changes, members) {
            let key = GitChangelistIdentity(change)
            if let previous = value.projectedMembership[key], previous != member { return nil }
            value.projectedMembership[key] = member
        }
        return value
    }
}
