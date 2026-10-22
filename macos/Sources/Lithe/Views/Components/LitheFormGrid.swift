import SwiftUI

/// Equal-width columns with ordered spans; layout never publishes geometry into feature state.
struct LitheFormGrid: Layout {
    struct Span: LayoutValueKey { static let defaultValue = 1 }
    let columns: Int

    func effectiveColumns(width: CGFloat) -> Int {
        width < LitheTheme.FormGrid.singleColumnBreakpoint ? 1 : max(1, columns)
    }

    func cellWidth(span: Int, width: CGFloat) -> CGFloat {
        let count = effectiveColumns(width: width)
        let span = min(count, max(1, span))
        let unit = max(0, width - CGFloat(count - 1) * LitheTheme.FormGrid.spacing) / CGFloat(count)
        return unit * CGFloat(span) + CGFloat(span - 1) * LitheTheme.FormGrid.spacing
    }

    /// Packing is shared by measurement and placement, including partial rows and mixed heights.
    func frames(width: CGFloat, spans: [Int], heights: [CGFloat]) -> [CGRect] {
        let count = effectiveColumns(width: width)
        let gap = LitheTheme.FormGrid.spacing
        var column = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return zip(spans, heights).map { requested, height in
            let span = min(count, max(1, requested))
            if column + span > count {
                y += rowHeight + gap
                column = 0
                rowHeight = 0
            }
            let x = CGFloat(column) * (cellWidth(span: 1, width: width) + gap)
            let frame = CGRect(x: x, y: y, width: cellWidth(span: span, width: width), height: height)
            column += span
            rowHeight = max(rowHeight, height)
            return frame
        }
    }

    private func measure(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let spans = subviews.map { $0[Span.self] }
        let heights = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: cellWidth(span: spans[index], width: width), height: nil)).height
        }
        return frames(width: width, spans: spans, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? LitheTheme.FormGrid.singleColumnBreakpoint
        let frames = measure(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, measure(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
