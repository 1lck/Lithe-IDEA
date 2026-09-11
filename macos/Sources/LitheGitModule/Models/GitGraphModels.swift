import Foundation

package struct GitGraphDisplayOptions: Hashable, Sendable {
    package static let compact = Self(longEdgeSize: 30, visiblePartSize: 1, edgeWithArrowSize: Int.max)
    package static let expanded = Self(longEdgeSize: 1_000, visiblePartSize: 250, edgeWithArrowSize: 30)

    let longEdgeSize: Int
    let visiblePartSize: Int
    let edgeWithArrowSize: Int
}

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
    /// Colors of compact row-center elements (including this row's node).
    /// Kept for the structural benchmark; routing uses explicit print elements.
    package let incomingLaneColors: [Int?]
    package let parentEdges: [GitGraphEdge]
    package let labels: [GitGraphLabel]
    package let layoutIndex: Int
    package let nodeColorIndex: Int
    package let printElements: [GitGraphPrintElement]

    package var id: String { commit.id }
    package var isMerge: Bool { commit.parentHashes.count > 1 }
    package var isRoot: Bool { commit.parentHashes.isEmpty }
}

/// A half-edge connects row centers through their shared boundary midpoint.
/// The two halves may occupy different columns without breaking continuity.
package struct GitGraphPrintElement: Identifiable, Hashable, Sendable {
    package enum Direction: String, Hashable, Sendable { case up, down }

    package let edgeID: String
    package let position: Int
    package let adjacentPosition: Int
    package let direction: Direction
    package let colorIndex: Int
    package let isDotted: Bool
    package let hasArrow: Bool
    /// Terminal arrows have no matching half-edge in the next row.
    package let isTerminal: Bool
    /// Loaded, visible endpoint. Missing-history markers never invent a target.
    package let targetHash: String?

    package var id: String { "\(edgeID):\(direction.rawValue)" }
}

package struct GitGraphLayout: Sendable {
    package let rows: [GitGraphRow]
    package let laneCount: Int
    package let hasMissingParents: Bool
    package let recommendedLaneCount: Int

    package init(rows: [GitGraphRow], laneCount: Int, hasMissingParents: Bool, recommendedLaneCount: Int = 0) {
        self.rows = rows
        self.laneCount = laneCount
        self.hasMissingParents = hasMissingParents
        self.recommendedLaneCount = recommendedLaneCount
    }
}

/// Renderer-neutral routing snapshot consumed by the native graph surface.
package struct GitGraphRoutingSnapshot: Equatable, Sendable {
    package let rows: [GitGraphRoutingRow]
    package let laneCount: Int
    package let recommendedLaneCount: Int

    package init(rows: [GitGraphRoutingRow], laneCount: Int, recommendedLaneCount: Int = 0) {
        self.rows = rows
        self.laneCount = laneCount
        self.recommendedLaneCount = recommendedLaneCount
    }
}

package struct GitGraphRoutingRow: Equatable, Sendable {
    package let rowIndex: Int
    package let nodeLane: Int
    package let incoming: [GitGraphRoutingSegment]
    package let routes: [GitGraphRoutingRoute]
    package let nodeColorIndex: Int
    package let isMerge: Bool
    package let printElements: [GitGraphPrintElement]

    package init(rowIndex: Int, nodeLane: Int, incoming: [GitGraphRoutingSegment], routes: [GitGraphRoutingRoute], nodeColorIndex: Int, isMerge: Bool, printElements: [GitGraphPrintElement]) {
        self.rowIndex = rowIndex
        self.nodeLane = nodeLane
        self.incoming = incoming
        self.routes = routes
        self.nodeColorIndex = nodeColorIndex
        self.isMerge = isMerge
        self.printElements = printElements
    }
}

package struct GitGraphRoutingSegment: Equatable, Sendable {
    package let lane: Int
    package let colorIndex: Int

    package init(lane: Int, colorIndex: Int) {
        self.lane = lane
        self.colorIndex = colorIndex
    }
}

package struct GitGraphRoutingRoute: Equatable, Sendable {
    package let targetLane: Int?
    package let colorIndex: Int
    package let isMissing: Bool

    package init(targetLane: Int?, colorIndex: Int, isMissing: Bool) {
        self.targetLane = targetLane
        self.colorIndex = colorIndex
        self.isMissing = isMissing
    }
}
