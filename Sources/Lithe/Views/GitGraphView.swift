import AppKit
import SwiftUI

struct GitGraphView: View {
    let layout: GitGraphLayout
    let visibleHashes: Set<String>?
    let selectedHash: String?
    let showCommitDecorations: Bool
    let onSelect: (GitCommit) -> Void
    let onCherryPick: (GitCommit) -> Void
    let onRevert: (GitCommit) -> Void
    let onReset: (GitCommit) -> Void

    @State private var hoveredHash: String?

    private let rowHeight: CGFloat = 39

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                GitGraphRowView(
                    row: row,
                    graphWidth: graphWidth,
                    rowHeight: rowHeight,
                    isSelected: selectedHash == row.commit.hash,
                    isHovered: hoveredHash == row.commit.hash,
                    showCommitDecorations: showCommitDecorations,
                    stripeIndex: index,
                    onSelect: { onSelect(row.commit) },
                    onCherryPick: { onCherryPick(row.commit) },
                    onRevert: { onRevert(row.commit) },
                    onReset: { onReset(row.commit) },
                    onHover: { isHovering in
                        hoveredHash = isHovering ? row.commit.hash : nil
                    }
                )
                .id(row.commit.hash)
            }

            if layout.hasMissingParents {
                HStack(spacing: 7) {
                    Image(systemName: "ellipsis")
                    Text("Older commits are outside the loaded history")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, graphWidth + 10)
                .frame(height: 30)
            }
        }
    }

    private var graphWidth: CGFloat {
        max(54, CGFloat(max(layout.laneCount, 1)) * 18 + 20)
    }

    private var visibleRows: [GitGraphRow] {
        guard let visibleHashes else { return layout.rows }
        return layout.rows.filter { visibleHashes.contains($0.commit.hash) }
    }
}

private struct GitGraphRowView: View {
    let row: GitGraphRow
    let graphWidth: CGFloat
    let rowHeight: CGFloat
    let isSelected: Bool
    let isHovered: Bool
    let showCommitDecorations: Bool
    let stripeIndex: Int
    let onSelect: () -> Void
    let onCherryPick: () -> Void
    let onRevert: () -> Void
    let onReset: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                GitGraphCanvas(
                    row: row,
                    width: graphWidth,
                    height: rowHeight,
                    isHighlighted: isHovered
                )

                HStack(spacing: 5) {
                    if showCommitDecorations {
                        ForEach(row.labels) { label in
                            GitGraphLabelView(label: label)
                        }
                    }
                    Text(row.commit.subject)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.commit.authorName)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)

                Text(row.commit.date)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 122, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .background(backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .onHover(perform: onHover)
        .contextMenu {
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.commit.hash, forType: .string)
            }
            Button("Copy Short Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.commit.shortHash, forType: .string)
            }
            Divider()
            Button("Cherry-pick Commit…", action: onCherryPick)
            Button("Revert Commit…", action: onRevert)
            Button("Reset Current Branch to Here…", action: onReset)
        }
    }

    private var backgroundColor: Color {
        if isSelected { return LitheTheme.selection }
        if isHovered { return LitheTheme.hoverBackground }
        return stripeIndex.isMultiple(of: 2) ? Color.white.opacity(0.012) : .clear
    }
}

private struct GitGraphLabelView: View {
    let label: GitGraphLabel

    var body: some View {
        Text(label.title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(foregroundColor.opacity(0.42), lineWidth: 0.6)
            }
    }

    private var foregroundColor: Color {
        switch label.kind {
        case .head: return LitheTheme.accent
        case .branch: return LitheTheme.success
        case .remote: return Color(red: 0.55, green: 0.70, blue: 0.96)
        case .tag: return LitheTheme.warning
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.16)
    }
}

private struct GitGraphCanvas: View {
    let row: GitGraphRow
    let width: CGFloat
    let height: CGFloat
    let isHighlighted: Bool

    private let laneSpacing: CGFloat = 18
    private let leftPadding: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let currentX = x(for: row.lane)

            for (lane, colorIndex) in row.incomingLaneColors.enumerated() {
                let path = linePath(
                    from: CGPoint(x: x(for: lane), y: 0),
                    to: CGPoint(x: x(for: lane), y: lane == row.lane ? centerY : size.height)
                )
                context.stroke(
                    path,
                    with: .color(GitGraphPalette.color(for: colorIndex)),
                    style: StrokeStyle(lineWidth: isHighlighted ? 2.3 : 1.8, lineCap: .round)
                )
            }

            for edge in row.parentEdges {
                let color = GitGraphPalette.color(for: edge.colorIndex)
                if let targetLane = edge.targetLane {
                    let target = CGPoint(x: x(for: targetLane), y: size.height)
                    let start = CGPoint(x: currentX, y: centerY)
                    var path = Path()
                    path.move(to: start)
                    if targetLane == row.lane {
                        path.addLine(to: target)
                    } else {
                        let controlY = centerY + (size.height - centerY) * 0.62
                        path.addCurve(
                            to: target,
                            control1: CGPoint(x: start.x, y: controlY),
                            control2: CGPoint(x: target.x, y: controlY)
                        )
                    }
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: isHighlighted ? 2.3 : 1.8, lineCap: .round)
                    )
                } else {
                    let path = linePath(
                        from: CGPoint(x: currentX, y: centerY),
                        to: CGPoint(x: currentX, y: size.height - 2)
                    )
                    context.stroke(
                        path,
                        with: .color(color.opacity(0.65)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 2])
                    )
                }
            }

            let nodeSize: CGFloat = row.isMerge ? 11 : 9
            let nodeRect = CGRect(
                x: currentX - nodeSize / 2,
                y: centerY - nodeSize / 2,
                width: nodeSize,
                height: nodeSize
            )
            context.fill(
                Path(ellipseIn: nodeRect),
                with: .color(GitGraphPalette.color(for: nodeColorIndex))
            )
            if row.isMerge {
                context.stroke(
                    Path(ellipseIn: nodeRect.insetBy(dx: 1, dy: 1)),
                    with: .color(Color.white.opacity(0.72)),
                    style: StrokeStyle(lineWidth: 1)
                )
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private var nodeColorIndex: Int {
        row.incomingLaneColors[safe: row.lane] ?? 0
    }

    private func x(for lane: Int) -> CGFloat {
        leftPadding + CGFloat(lane) * laneSpacing
    }

    private func linePath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}

private enum GitGraphPalette {
    private static let colors: [Color] = [
        Color(red: 0.29, green: 0.72, blue: 0.45),
        Color(red: 0.35, green: 0.62, blue: 0.96),
        Color(red: 0.82, green: 0.47, blue: 0.82),
        Color(red: 0.96, green: 0.61, blue: 0.28),
        Color(red: 0.36, green: 0.78, blue: 0.78),
        Color(red: 0.93, green: 0.42, blue: 0.48),
        Color(red: 0.70, green: 0.63, blue: 0.94)
    ]

    static func color(for index: Int) -> Color {
        colors[index % colors.count]
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
