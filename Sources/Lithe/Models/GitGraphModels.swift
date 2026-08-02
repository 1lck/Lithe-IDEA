import Foundation

enum GitGraphReferenceKind: String, Hashable, Sendable {
    case head
    case branch
    case remote
    case tag
}

struct GitGraphLabel: Identifiable, Hashable, Sendable {
    let title: String
    let kind: GitGraphReferenceKind

    var id: String { "\(kind.rawValue):\(title)" }
}

struct GitGraphEdge: Identifiable, Hashable, Sendable {
    let id: String
    let parentHash: String
    let targetLane: Int?
    let colorIndex: Int
    let isMissing: Bool
}

struct GitGraphRow: Identifiable, Hashable, Sendable {
    let commit: GitCommit
    let lane: Int
    let laneCount: Int
    let incomingLaneColors: [Int]
    let parentEdges: [GitGraphEdge]
    let labels: [GitGraphLabel]

    var id: String { commit.id }
    var isMerge: Bool { commit.parentHashes.count > 1 }
    var isRoot: Bool { commit.parentHashes.isEmpty }
}

struct GitGraphLayout: Sendable {
    let rows: [GitGraphRow]
    let laneCount: Int
    let hasMissingParents: Bool
}
