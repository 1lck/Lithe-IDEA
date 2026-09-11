import AppKit
import LitheGitModule

/// One geometry definition for drawing, pointer targets and accessible buttons.
enum GitGraphGeometry {
    static let laneSpacing: CGFloat = 13
    static let leftPadding: CGFloat = 8

    static func maximumWidth(laneCount: Int, recommendedLaneCount: Int) -> CGFloat {
        max(30, CGFloat(max(laneCount, min(6, recommendedLaneCount))) * laneSpacing + 16)
    }

    /// GraphCommitCellUtil includes diagonal boundary midpoints, then reserves
    /// up to six recommended columns. A dense row cannot widen all other rows.
    static func rowWidth(_ row: GitGraphRow, recommendedLaneCount: Int) -> CGFloat {
        let lastPosition = row.printElements.reduce(CGFloat(row.lane)) {
            max($0, CGFloat($1.position), CGFloat($1.position + $1.adjacentPosition) / 2)
        }
        let columns = max(lastPosition + 1, CGFloat(min(6, recommendedLaneCount)))
        return max(30, columns * laneSpacing + 16)
    }

    static func line(for element: GitGraphPrintElement, rowHeight: CGFloat) -> (start: CGPoint, end: CGPoint) {
        let start = CGPoint(x: leftPadding + CGFloat(element.position) * laneSpacing, y: rowHeight / 2)
        let sign: CGFloat = element.direction == .up ? -1 : 1
        let end = CGPoint(
            x: leftPadding + CGFloat(element.position + element.adjacentPosition) / 2 * laneSpacing,
            y: rowHeight / 2 + sign * (rowHeight / 2 - (element.isTerminal ? 3 : 0))
        )
        return (start, end)
    }

    static func arrowHitRect(for element: GitGraphPrintElement, rowHeight: CGFloat) -> CGRect {
        let segment = line(for: element, rowHeight: rowHeight)
        let center = CGPoint(x: (segment.start.x + segment.end.x) / 2, y: (segment.start.y + segment.end.y) / 2)
        return CGRect(x: center.x - 6, y: max(0, center.y - 7), width: 12, height: 14)
    }
}
