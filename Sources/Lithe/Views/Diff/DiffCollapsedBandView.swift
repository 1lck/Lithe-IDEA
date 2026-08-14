import SwiftUI

/// Clickable band standing in for a folded run of unchanged lines.
struct DiffCollapsedBandView: View {
    let region: DiffCollapsedRegion
    let contentWidth: CGFloat
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.accent)
                Text("\(region.hiddenRowCount) unchanged lines")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(height: 1)
            }
            .padding(.horizontal, 10)
            .frame(width: contentWidth, height: DiffLayoutMetrics.informationRowHeight, alignment: .leading)
            .background(LitheTheme.window)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help("Expand these lines")
    }
}
