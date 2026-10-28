import SwiftUI

/// Puts two views side by side when each keeps at least `minimumColumnWidth`, and stacks them
/// when the row is narrower. The columns share the row equally and align to the top.
struct LitheAdaptiveColumnsLayout: Layout {
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat

    private func columnWidth(for width: CGFloat?, count: Int) -> CGFloat? {
        guard count == 2, let width, width.isFinite else { return nil }
        let column = (width - spacing) / 2
        return column >= minimumColumnWidth ? column : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let column = columnWidth(for: proposal.width, count: subviews.count), let width = proposal.width {
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let column = columnWidth(for: bounds.width, count: subviews.count) {
            for (index, subview) in subviews.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: bounds.minY),
                              proposal: ProposedViewSize(width: column, height: nil))
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
    }
}
