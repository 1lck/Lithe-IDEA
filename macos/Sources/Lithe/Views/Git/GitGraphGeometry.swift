import AppKit
import LitheGitModule

/// One geometry definition for drawing, pointer targets and accessible buttons.
enum GitGraphGeometry {
    // New UI's VersionControl.Log uses 26pt rows. PaintParameters scales
    // every graph measurement from its 22pt baseline with the row height.
    static let rowHeight = rowHeight(for: LitheTheme.uiNSFont(size: LitheTheme.GitLog.fontSize))

    // GraphCommitCellRenderer: max(New UI minimum, FontMetrics height + vertical padding).
    static func rowHeight(for font: NSFont) -> CGFloat {
        max(26, ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading) + 7)
    }

    // SimpleColoredComponent.getTextBaseLine, including JetBrains Runtime's leading.
    static func textBaseline(for font: NSFont, height: CGFloat) -> CGFloat {
        let ascent = ceil(font.ascender)
        let descent = ceil(-font.descender)
        let leading = ceil(font.leading)
        return floor((height - ascent - descent - leading + 1) / 2) + ascent + leading
    }
    private static let paintScale = rowHeight / 22
    static let laneSpacing: CGFloat = 16 * paintScale
    static let graphTextGap: CGFloat = 2 * paintScale

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

    /// Keep the screenshot's six-column title gutter; dense rows may grow beyond it.
    /// Use GraphCommitCellUtil's scaled grid and SimpleColoredComponent's 2pt text inset.
    static func titleOffset(_ row: GitGraphRow, recommendedLaneCount: Int) -> CGFloat {
        floor(rowWidth(row, recommendedLaneCount: max(6, recommendedLaneCount))) + 2
    }

    static func line(for element: GitGraphPrintElement, rowHeight: CGFloat, backingScale: CGFloat = 1) -> (start: CGPoint, end: CGPoint) {
        PaintMetrics(rowHeight: rowHeight, backingScale: backingScale).line(for: element)
    }

    static func arrowHitRect(for element: GitGraphPrintElement, rowHeight: CGFloat, backingScale: CGFloat = 1) -> CGRect {
        PaintMetrics(rowHeight: rowHeight, backingScale: backingScale).arrowHitRect(for: element)
    }

    /// SimpleGraphCellPainter.MyPainter / PaintUtil: floor to odd device pixels.
    /// Layout keeps its logical grid; drawing and navigation use this aligned grid.
    struct PaintMetrics {
        let rowHeight: CGFloat
        let rowCenter: CGFloat
        let laneSpacing: CGFloat
        let laneCenter: CGFloat
        let lineWidth: CGFloat
        let nodeDiameter: CGFloat
        let nodeRadius: CGFloat
        private let pixel: CGFloat

        init(rowHeight: CGFloat, backingScale: CGFloat) {
            let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
            func align(_ value: CGFloat, odd: Bool = false) -> CGFloat {
                var pixels = floor(value * scale)
                if odd && pixels.truncatingRemainder(dividingBy: 2) == 0 { pixels -= 1 }
                return pixels / scale
            }
            self.rowHeight = rowHeight
            pixel = 1 / scale
            rowCenter = align(rowHeight / 2, odd: true)
            laneSpacing = align(16 * rowHeight / 22, odd: true)
            laneCenter = align(8 * rowHeight / 22)
            lineWidth = max(pixel, align(1.5 * rowHeight / 22, odd: true))
            nodeDiameter = align(8 * rowHeight / 22, odd: true)
            nodeRadius = align(nodeDiameter / 2)
        }

        func nodeRect(lane: Int) -> CGRect {
            CGRect(x: laneCenter + CGFloat(lane) * laneSpacing - nodeRadius,
                   y: rowCenter - nodeRadius, width: nodeDiameter, height: nodeDiameter)
        }

        func line(for element: GitGraphPrintElement) -> (start: CGPoint, end: CGPoint) {
            let start = CGPoint(x: laneCenter + CGFloat(element.position) * laneSpacing, y: rowCenter)
            let endY: CGFloat
            if element.position == element.adjacentPosition {
                let gap = element.isTerminal ? nodeRadius / 2 + 1 : 0
                endY = element.direction == .up ? gap : rowHeight - gap
            } else {
                endY = rowCenter + (element.direction == .up ? -rowHeight : rowHeight) / 2
            }
            return (start, CGPoint(x: laneCenter + CGFloat(element.position + element.adjacentPosition) / 2 * laneSpacing, y: endY))
        }

        func arrowArms(for element: GitGraphPrintElement) -> [CGPoint] {
            let segment = line(for: element)
            let length = max(1, hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y))
            let vx = (segment.start.x - segment.end.x) / length * rowHeight * 0.3
            let vy = (segment.start.y - segment.end.y) / length * rowHeight * 0.3
            return [CGFloat(-1), 1].map { sign in
                CGPoint(x: segment.end.x + vx * sqrt(0.7) - sign * vy * sqrt(0.3),
                        y: segment.end.y + sign * vx * sqrt(0.3) + vy * sqrt(0.7))
            }
        }

        func arrowHitRect(for element: GitGraphPrintElement) -> CGRect {
            let tip = line(for: element).end
            let halfRow = CGRect(x: tip.x - 6, y: element.direction == .up ? 0 : rowHeight / 2,
                                 width: 12, height: rowHeight / 2)
            // Include the aligned tip, even when it crosses a logical row boundary.
            return halfRow.union(CGRect(x: tip.x - 6, y: tip.y - pixel, width: 12, height: 2 * pixel))
        }
    }
}
