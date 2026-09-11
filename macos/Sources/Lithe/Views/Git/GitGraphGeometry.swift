import AppKit
import LitheGitModule

/// One geometry definition for drawing, pointer targets and accessible buttons.
enum GitGraphGeometry {
    // IntelliJ PaintParameters at its native 22 pt row height. Keep the whole
    // geometry together: stretched rows with narrow columns exaggerate zigzags.
    static let rowHeight: CGFloat = 22
    static let laneSpacing: CGFloat = 16
    static let leftPadding: CGFloat = 8
    static let lineWidth: CGFloat = 1.5
    static let nodeDiameter: CGFloat = 8
    static let graphTextGap: CGFloat = 2

    static func maximumWidth(laneCount: Int, recommendedLaneCount: Int) -> CGFloat {
        CGFloat(max(1, laneCount, min(6, recommendedLaneCount))) * laneSpacing + graphTextGap
    }

    /// GraphCommitCellUtil includes diagonal boundary midpoints, then reserves
    /// up to six recommended columns. A dense row cannot widen all other rows.
    static func rowWidth(_ row: GitGraphRow, recommendedLaneCount: Int) -> CGFloat {
        let lastPosition = row.printElements.reduce(CGFloat(row.lane)) {
            max($0, CGFloat($1.position), CGFloat($1.position + $1.adjacentPosition) / 2)
        }
        let columns = max(lastPosition + 1, CGFloat(min(6, recommendedLaneCount)))
        return columns * laneSpacing + graphTextGap
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
        let centerX = segment.end.x
        // Keep up/down targets in their own half of a compact row.
        return CGRect(x: centerX - 6, y: element.direction == .up ? 0 : rowHeight / 2,
                      width: 12, height: rowHeight / 2)
    }
}
