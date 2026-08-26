import Foundation

package enum GitGraphReferenceKind: String, Hashable, Sendable {
    case head
    case branch
    case remote
    case tag
}

package struct GitGraphLabel: Identifiable, Hashable, Sendable {
    package let title: String
    package let kind: GitGraphReferenceKind

    package var id: String { "\(kind.rawValue):\(title)" }
}

package struct GitGraphEdge: Identifiable, Hashable, Sendable {
    package let id: String
    package let parentHash: String
    package let targetLane: Int?
    package let colorIndex: Int
    package let isMissing: Bool
}

package struct GitGraphRow: Identifiable, Hashable, Sendable {
    package let commit: GitCommit
    package let lane: Int
    package let laneCount: Int
    /// One entry per lane slot, ordered by lane index. `nil` marks a slot that no
    /// branch occupies at this row, so lane indices stay stable between rows.
    package let incomingLaneColors: [Int?]
    package let parentEdges: [GitGraphEdge]
    package let labels: [GitGraphLabel]

    package var id: String { commit.id }
    package var isMerge: Bool { commit.parentHashes.count > 1 }
    package var isRoot: Bool { commit.parentHashes.isEmpty }
}

package struct GitGraphLayout: Sendable {
    package let rows: [GitGraphRow]
    package let laneCount: Int
    package let hasMissingParents: Bool

    package init(rows: [GitGraphRow], laneCount: Int, hasMissingParents: Bool) {
        self.rows = rows
        self.laneCount = laneCount
        self.hasMissingParents = hasMissingParents
    }
}
