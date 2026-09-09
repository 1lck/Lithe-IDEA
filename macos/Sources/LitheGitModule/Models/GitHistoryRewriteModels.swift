import Foundation

/// History actions share Core's preflight and optimistic state check.
public enum GitHistoryRewriteOperation: String, Codable, Sendable, CaseIterable {
    case undoCommit
    case editCommitMessage
    case squashCommits
    case deleteCommit

    package var editsMessage: Bool { self == .editCommitMessage || self == .squashCommits }
}

package struct GitHistoryRewriteCommit: Decodable, Equatable, Sendable, Identifiable {
    package let hash: String
    package let parents: [String]
    package let message: String
    package var id: String { hash }
    package var subject: String { message.components(separatedBy: "\n").first ?? "" }
}

package struct GitHistoryRewriteBlocker: Decodable, Equatable, Sendable {
    package let code: String
    package let message: String
}

/// The exact Core preview snapshot is echoed at execution; UI guesses never authorize a rewrite.
package struct GitHistoryRewriteExpectedState: Codable, Equatable, Sendable {
    package let branch: String
    package let head: String
    package let stateToken: String
    package let operation: GitHistoryRewriteOperation
    package let revisions: [String]
}

package struct GitHistoryRewritePreview: Decodable, Equatable, Sendable {
    package let operation: GitHistoryRewriteOperation
    package let allowed: Bool
    package let blockers: [GitHistoryRewriteBlocker]
    package let branch: String?
    package let head: String?
    /// Commits are ordered oldest to newest, independently of Log filtering and pagination.
    package let selectedCommits: [GitHistoryRewriteCommit]
    package let affectedCommits: [GitHistoryRewriteCommit]
    package let suggestedMessage: String
    package let expectedState: GitHistoryRewriteExpectedState?

    package static func failed(operation: GitHistoryRewriteOperation, message: String) -> Self {
        Self(
            operation: operation, allowed: false,
            blockers: [GitHistoryRewriteBlocker(code: "preview_failed", message: message)],
            branch: nil, head: nil, selectedCommits: [], affectedCommits: [],
            suggestedMessage: "", expectedState: nil
        )
    }
}

public struct GitHistoryRewriteResult: Decodable, Equatable, Sendable {
    package let operation: GitHistoryRewriteOperation
    package let branch: String
    package let originalHead: String
    package let newHead: String?
    package let recoveryReference: String
    package let mutationApplied: Bool
    package let outcomeKnown: Bool
    package let worktreeRefresh: String
}

/// Selection stores commit identities, so appending a page cannot move the range anchor.
package struct GitHistorySelection: Equatable, Sendable {
    package private(set) var hashes: Set<String> = []
    package private(set) var focusedHash: String?
    package private(set) var anchorHash: String?

    package init() {}

    package mutating func select(_ hash: String, visibleHashes: [String], additive: Bool = false, range: Bool = false) {
        if range, let anchorHash, let start = visibleHashes.firstIndex(of: anchorHash),
           let end = visibleHashes.firstIndex(of: hash) {
            let interval = Set(visibleHashes[min(start, end)...max(start, end)])
            hashes = additive ? hashes.union(interval) : interval
        } else if additive {
            if hashes.contains(hash) { hashes.remove(hash) } else { hashes.insert(hash) }
            anchorHash = hash
        } else {
            hashes = [hash]
            anchorHash = hash
        }
        focusedHash = hash
    }

    package mutating func selectForContextMenu(_ hash: String) {
        if !hashes.contains(hash) {
            hashes = [hash]
            anchorHash = hash
        }
        focusedHash = hash
    }

    /// Only a complete history replacement prunes missing identities; paging leaves them intact.
    package mutating func retain(_ loadedHashes: Set<String>, fallback: String?) {
        hashes.formIntersection(loadedHashes)
        if hashes.isEmpty, let fallback, loadedHashes.contains(fallback) { hashes = [fallback] }
        if focusedHash.map(loadedHashes.contains) != true { focusedHash = fallback }
        if anchorHash.map(loadedHashes.contains) != true { anchorHash = focusedHash }
    }
}
