import AppKit
import SwiftUI
import LitheGitModule

/// Commit-row callbacks are grouped so that a row receives one stable value
/// instead of four freshly allocated closures per redraw. Rows are compared by
/// their rendered data alone, which keeps SwiftUI from re-evaluating hundreds of
/// canvases and context menus whenever an unrelated observable changes.
struct GitGraphRowActions {
    let onSelect: (GitCommit) -> Void
    let onCherryPick: (GitCommit) -> Void
    let onRevert: (GitCommit) -> Void
    let onReset: (GitCommit) -> Void
}

struct GitGraphView: View {
    let layout: GitGraphLayout
    let visibleHashes: Set<String>?
    let selectedHash: String?
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions

    private let rowHeight: CGFloat = 30

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(visibleRows) { row in
                GitGraphRowView(
                    row: row,
                    graphWidth: graphWidth(for: row),
                    rowHeight: rowHeight,
                    isSelected: selectedHash == row.commit.hash,
                    showCommitDecorations: showCommitDecorations,
                    actions: actions
                )
                .equatable()
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
                .padding(.leading, maximumGraphWidth + 6)
                .frame(height: 30)
            }
        }
    }

    private func graphWidth(for row: GitGraphRow) -> CGFloat {
        max(30, CGFloat(max(row.laneCount, 1)) * 13 + 16)
    }

    private var maximumGraphWidth: CGFloat {
        max(30, CGFloat(max(layout.laneCount, 1)) * 13 + 16)
    }

    private var visibleRows: [GitGraphRow] {
        guard let visibleHashes else { return layout.rows }
        return layout.rows.filter { visibleHashes.contains($0.commit.hash) }
    }
}

private struct GitGraphRowView: View, Equatable {
    let row: GitGraphRow
    let graphWidth: CGFloat
    let rowHeight: CGFloat
    let isSelected: Bool
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions

    @State private var isHovered = false

    static func == (lhs: GitGraphRowView, rhs: GitGraphRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.graphWidth == rhs.graphWidth
            && lhs.rowHeight == rhs.rowHeight
            && lhs.isSelected == rhs.isSelected
            && lhs.showCommitDecorations == rhs.showCommitDecorations
    }

    var body: some View {
        Button { actions.onSelect(row.commit) } label: {
            HStack(spacing: 0) {
                GitGraphCanvas(
                    row: row,
                    width: graphWidth,
                    height: rowHeight
                )

                HStack(spacing: 0) {
                    if showCommitDecorations, !row.labels.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(row.labels) { label in
                                GitGraphLabelView(label: label)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    Text(row.commit.subject)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.commit.authorName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)

                Text(row.commit.date)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 118, alignment: .trailing)
            }
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .background(backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
            Button("Cherry-pick Commit…") { actions.onCherryPick(row.commit) }
            Button("Revert Commit…") { actions.onRevert(row.commit) }
            Button("Reset Current Branch to Here…") { actions.onReset(row.commit) }
        }
    }

    private var backgroundColor: Color {
        if isSelected { return LitheTheme.selection }
        if isHovered { return LitheTheme.hoverBackground }
        return .clear
    }
}

private struct GitGraphLabelView: View {
    let label: GitGraphLabel

    var body: some View {
        HStack(spacing: 2) {
            GitReferenceTagIcon(color: accentColor)
                .frame(width: 12, height: 12)
            Text(label.title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(LitheTheme.primaryText.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 4)
        .frame(height: 17)
        .background(LitheTheme.primaryText.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var accentColor: Color {
        switch label.kind {
        case .head: return LitheTheme.accent
        case .branch: return LitheTheme.success
        case .remote: return Color(red: 0.55, green: 0.70, blue: 0.96)
        case .tag: return LitheTheme.warning
        }
    }
}

private struct GitReferenceTagIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 6.25
            let origin = CGPoint(
                x: (size.width - 5.25 * scale) / 2,
                y: (size.height - 5 * scale) / 2
            )
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + 2 * scale, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + 5 * scale, y: origin.y + 3 * scale))
            path.addLine(to: CGPoint(x: origin.x + 3 * scale, y: origin.y + 5 * scale))
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + 2 * scale))
            path.closeSubpath()
            path.addEllipse(in: CGRect(
                x: origin.x + scale,
                y: origin.y + scale,
                width: scale,
                height: scale
            ))
            context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)
    }
}

private struct GitGraphCanvas: View {
    let row: GitGraphRow
    let width: CGFloat
    let height: CGFloat

    private let laneSpacing: CGFloat = 13
    private let laneLineWidth: CGFloat = 1.6
    private let leftPadding: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let currentX = x(for: row.lane)

            for (lane, incomingColorIndex) in row.incomingLaneColors.enumerated() {
                guard let colorIndex = incomingColorIndex else { continue }
                let path = linePath(
                    from: CGPoint(x: x(for: lane), y: 0),
                    to: CGPoint(x: x(for: lane), y: lane == row.lane ? centerY : size.height)
                )
                context.stroke(
                    path,
                    with: .color(GitGraphPalette.color(for: colorIndex)),
                    style: StrokeStyle(lineWidth: laneLineWidth, lineCap: .round)
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
                        style: StrokeStyle(lineWidth: laneLineWidth, lineCap: .round)
                    )
                } else {
                    let path = linePath(
                        from: CGPoint(x: currentX, y: centerY),
                        to: CGPoint(x: currentX, y: size.height - 2)
                    )
                    context.stroke(
                        path,
                        with: .color(color.opacity(0.65)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 2])
                    )
                }
            }

            let nodeSize: CGFloat = row.isMerge ? 9.5 : 8.5
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
        row.incomingLaneColors[safe: row.lane].flatMap { $0 }
            ?? row.parentEdges.first?.colorIndex
            ?? 0
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
