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
    let onCreateTag: (GitCommit) -> Void
}

struct GitGraphView: View {
    let layout: GitGraphLayout
    let visibleHashes: Set<String>?
    let selectedHash: String?
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions

    private let rowHeight: CGFloat = 30

    var body: some View {
        let routing = GitGraphLayoutService.routingSnapshot(
            for: GitGraphLayout(rows: visibleRows, laneCount: layout.laneCount, hasMissingParents: layout.hasMissingParents)
        )
        ZStack(alignment: .topLeading) {
            LazyVStack(spacing: 0) {
                ForEach(visibleRows) { row in
                    GitGraphRowView(
                        row: row,
                        graphWidth: maximumGraphWidth,
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

            GitGraphNSViewRepresentable(
                snapshot: routing,
                width: maximumGraphWidth,
                rowHeight: rowHeight
            )
            .frame(width: maximumGraphWidth, height: CGFloat(visibleRows.count) * rowHeight)
            .allowsHitTesting(false)
        }
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
                Color.clear.frame(width: graphWidth, height: rowHeight)

                HStack(spacing: 0) {
                    Text(row.commit.subject)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)

                    if showCommitDecorations, !row.labels.isEmpty {
                        Spacer(minLength: 8)

                        HStack(spacing: 6) {
                            ForEach(row.labels) { label in
                                GitGraphLabelView(label: label)
                            }
                        }
                        .padding(.trailing, 4)
                    }
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
            Button("New Tag…") { actions.onCreateTag(row.commit) }
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

private struct GitGraphNSViewRepresentable: NSViewRepresentable {
    let snapshot: GitGraphRoutingSnapshot
    let width: CGFloat
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> GitGraphNSView {
        GitGraphNSView()
    }

    func updateNSView(_ nsView: GitGraphNSView, context: Context) {
        nsView.update(snapshot: snapshot, width: width, rowHeight: rowHeight)
    }
}

private final class GitGraphNSView: NSView {
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.29, green: 0.72, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.82, green: 0.47, blue: 0.82, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.61, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.48, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.63, blue: 0.94, alpha: 1)
    ]

    private var snapshot = GitGraphRoutingSnapshot(rows: [], laneCount: 0)
    private var graphWidth: CGFloat = 0
    private var rowHeight: CGFloat = 30
    private let laneSpacing: CGFloat = 13
    private let laneLineWidth: CGFloat = 1.6
    private let leftPadding: CGFloat = 8

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    func update(snapshot: GitGraphRoutingSnapshot, width: CGFloat, rowHeight: CGFloat) {
        guard self.snapshot != snapshot || graphWidth != width || self.rowHeight != rowHeight else { return }
        self.snapshot = snapshot
        graphWidth = width
        self.rowHeight = rowHeight
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)

        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow = min(snapshot.rows.count - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard firstRow <= lastRow else { return }

        for index in firstRow...lastRow {
            let row = snapshot.rows[index]
            let top = CGFloat(index) * rowHeight
            let centerY = top + rowHeight / 2
            let currentX = x(for: row.nodeLane)

            for segment in row.incoming {
                stroke(
                    line(from: CGPoint(x: x(for: segment.lane), y: top), to: CGPoint(x: x(for: segment.lane), y: segment.lane == row.nodeLane ? centerY : top + rowHeight)),
                    color: color(for: segment.colorIndex),
                    width: laneLineWidth,
                    context: context
                )
            }

            for route in row.routes {
                let color = color(for: route.colorIndex)
                if let targetLane = route.targetLane {
                    let target = CGPoint(x: x(for: targetLane), y: top + rowHeight)
                    let start = CGPoint(x: currentX, y: centerY)
                    let path: CGPath
                    if targetLane == row.nodeLane {
                        path = line(from: start, to: target)
                    } else {
                        let controlY = centerY + (rowHeight - rowHeight / 2) * 0.62
                        let bezier = CGMutablePath()
                        bezier.move(to: start)
                        bezier.addCurve(to: target, control1: CGPoint(x: start.x, y: controlY), control2: CGPoint(x: target.x, y: controlY))
                        path = bezier
                    }
                    stroke(path, color: color, width: laneLineWidth, context: context)
                } else {
                    context.saveGState()
                    context.setLineDash(phase: 0, lengths: [3, 2])
                    stroke(line(from: CGPoint(x: currentX, y: centerY), to: CGPoint(x: currentX, y: top + rowHeight - 2)), color: color.withAlphaComponent(0.65), width: 1.5, context: context)
                    context.restoreGState()
                }
            }

            let nodeSize: CGFloat = row.routes.count > 1 ? 9.5 : 8.5
            let nodeRect = CGRect(x: currentX - nodeSize / 2, y: centerY - nodeSize / 2, width: nodeSize, height: nodeSize)
            context.setFillColor(color(for: nodeColorIndex(row)).cgColor)
            context.fillEllipse(in: nodeRect)
            if row.routes.count > 1 {
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
                context.setLineWidth(1)
                context.strokeEllipse(in: nodeRect.insetBy(dx: 1, dy: 1))
            }
        }
    }

    private func nodeColorIndex(_ row: GitGraphRoutingRow) -> Int {
        row.incoming.first(where: { $0.lane == row.nodeLane })?.colorIndex ?? row.routes.first?.colorIndex ?? 0
    }

    private func x(for lane: Int) -> CGFloat { leftPadding + CGFloat(lane) * laneSpacing }

    private func line(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    private func stroke(_ path: CGPath, color: NSColor, width: CGFloat, context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func color(for index: Int) -> NSColor {
        Self.palette[index % Self.palette.count]
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
