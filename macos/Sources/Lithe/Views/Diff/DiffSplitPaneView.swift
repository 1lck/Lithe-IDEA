import SwiftUI
import LitheGitModule

/// IDEA-style side-by-side diff whose two code panes advance independently.
/// One-sided changes therefore never manufacture blank source rows; their
/// height difference is explained by the curved transition in the gutter.
struct DiffSplitPaneView<RowOverlay: View>: View {
    let displayRows: [DiffDisplayRow]
    let kinds: [DiffRowKind]
    let fileExtension: String
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let minimumHeight: CGFloat
    let highlightsWords: Bool
    let selectedRowIDs: Set<DiffRowID>
    let searchMatchIDs: Set<DiffRowID>
    let currentSearchMatchID: DiffRowID?
    let onExpand: (DiffCollapsedRegion) -> Void
    let rowOverlay: (DiffRow, DiffSide) -> RowOverlay

    @State private var horizontalOffset: CGFloat = 0
    @State private var wheelScheduler = LitheDragUpdateScheduler()
    @State private var leftPaneWidth: CGFloat?
    @State private var paneDragStart: CGFloat = 0

    init(
        displayRows: [DiffDisplayRow],
        kinds: [DiffRowKind],
        fileExtension: String,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        minimumHeight: CGFloat,
        highlightsWords: Bool = true,
        selectedRowIDs: Set<DiffRowID> = [],
        searchMatchIDs: Set<DiffRowID> = [],
        currentSearchMatchID: DiffRowID? = nil,
        onExpand: @escaping (DiffCollapsedRegion) -> Void,
        @ViewBuilder rowOverlay: @escaping (DiffRow, DiffSide) -> RowOverlay
    ) {
        self.displayRows = displayRows
        self.kinds = kinds
        self.fileExtension = fileExtension
        self.contentWidth = contentWidth
        self.viewportWidth = viewportWidth
        self.minimumHeight = minimumHeight
        self.highlightsWords = highlightsWords
        self.selectedRowIDs = selectedRowIDs
        self.searchMatchIDs = searchMatchIDs
        self.currentSearchMatchID = currentSearchMatchID
        self.onExpand = onExpand
        self.rowOverlay = rowOverlay
    }

    var body: some View {
        let layout = DiffSplitLayout.plan(displayRows: displayRows, kinds: kinds)
        let gutterWidth = DiffLayoutMetrics.centerGutterWidth
        let availablePaneWidth = max(0, viewportWidth - gutterWidth)
        let paneViewportWidth = max(
            0,
            min(availablePaneWidth, leftPaneWidth ?? availablePaneWidth / 2)
        )
        let rightPaneViewportWidth = max(0, availablePaneWidth - paneViewportWidth)
        let paneContentWidth = max(
            paneViewportWidth,
            (contentWidth - gutterWidth) / 2
        )
        let maximumHorizontalOffset = max(0, paneContentWidth - paneViewportWidth)
        let height = max(layout.contentHeight, minimumHeight)

        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 0) {
                        sideViewport(
                            layout.leftItems,
                            side: .left,
                            viewportWidth: paneViewportWidth,
                            contentWidth: paneContentWidth,
                            height: height
                        )
                        centerGutter
                        sideViewport(
                            layout.rightItems,
                            side: .right,
                            viewportWidth: rightPaneViewportWidth,
                            contentWidth: max(
                                rightPaneViewportWidth,
                                contentWidth - gutterWidth - paneViewportWidth
                            ),
                            height: height
                        )
                    }

                    DiffTransitionOverlay(
                        transitions: layout.transitions,
                        contentWidth: viewportWidth,
                        contentHeight: height
                    )
                }
                .frame(width: viewportWidth, height: height, alignment: .topLeading)
                .textSelection(.enabled)
            }
            .litheScrollViewChrome(hideHorizontal: true)

            DiffHorizontalScroller(
                offset: $horizontalOffset,
                viewportWidth: paneViewportWidth,
                contentWidth: paneContentWidth
            )
        }
        .overlay(alignment: .topLeading) {
            SplitHandleView(
                axis: .horizontal,
                showsIdleDivider: false,
                onDragStarted: {
                    paneDragStart = paneViewportWidth
                },
                onDragChanged: { translation in
                    leftPaneWidth = min(
                        max(paneDragStart + translation, 220),
                        max(220, availablePaneWidth - 220)
                    )
                },
                onDragEnded: { translation in
                    leftPaneWidth = min(
                        max(paneDragStart + translation, 220),
                        max(220, availablePaneWidth - 220)
                    )
                }
            )
            .offset(x: paneViewportWidth + gutterWidth / 2 - SplitHandleView.thickness / 2)
            .frame(height: minimumHeight)
        }
        .frame(width: viewportWidth, height: minimumHeight, alignment: .topLeading)
        .background {
            DiffHorizontalScrollWheelMonitor { delta in
                // Wheel deltas are incremental, so accumulate onto the in-flight
                // target rather than the last applied offset. minimumChange: 0
                // keeps sub-point wheel steps from being swallowed by the
                // deadband, matching the pre-scheduler behavior.
                let pendingOffset = wheelScheduler.pendingValue ?? horizontalOffset
                wheelScheduler.submit(
                    min(max(pendingOffset + delta, 0), maximumHorizontalOffset),
                    minimumChange: 0
                ) { nextOffset in
                    horizontalOffset = nextOffset
                }
            }
        }
        .onChange(of: contentWidth) { _ in
            wheelScheduler.cancel()
            horizontalOffset = min(horizontalOffset, maximumHorizontalOffset)
        }
        .onDisappear { wheelScheduler.cancel() }
    }

    private func sideViewport(
        _ items: [DiffSplitLayout.Item],
        side: DiffSide,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        sideColumn(items, side: side, width: contentWidth)
            .offset(x: -horizontalOffset)
            .frame(width: viewportWidth, height: height, alignment: .topLeading)
            .clipped()
            .background(LitheTheme.editor)
    }

    private var centerGutter: some View {
        LitheTheme.window
            .overlay(alignment: .leading) {
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
            }
            .frame(width: DiffLayoutMetrics.centerGutterWidth)
            .frame(maxHeight: .infinity)
    }

    private func sideColumn(
        _ items: [DiffSplitLayout.Item],
        side: DiffSide,
        width: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                sideItem(item, side: side, width: width)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    @ViewBuilder
    private func sideItem(
        _ item: DiffSplitLayout.Item,
        side: DiffSide,
        width: CGFloat
    ) -> some View {
        switch item.displayRow {
        case let .collapsed(region):
            DiffCollapsedBandView(region: region, contentWidth: width) {
                onExpand(region)
            }

        case let .row(row, _):
            let cell = DiffSideRowView(
                row: row,
                kind: item.kind,
                side: side,
                fileExtension: fileExtension,
                highlightsWords: highlightsWords,
                isSelectedDifference: selectedRowIDs.contains(row.id),
                isSearchMatch: searchMatchIDs.contains(row.id),
                isCurrentSearchMatch: currentSearchMatchID == row.id
            )
            .frame(width: width)
            .overlay(alignment: .topTrailing) {
                rowOverlay(row, side)
            }

            if item.isScrollAnchor {
                cell.id(row.id)
            } else {
                cell
            }
        }
    }
}

extension DiffSplitPaneView where RowOverlay == EmptyView {
    init(
        displayRows: [DiffDisplayRow],
        kinds: [DiffRowKind],
        fileExtension: String,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        minimumHeight: CGFloat,
        highlightsWords: Bool = true,
        selectedRowIDs: Set<DiffRowID> = [],
        searchMatchIDs: Set<DiffRowID> = [],
        currentSearchMatchID: DiffRowID? = nil,
        onExpand: @escaping (DiffCollapsedRegion) -> Void
    ) {
        self.init(
            displayRows: displayRows,
            kinds: kinds,
            fileExtension: fileExtension,
            contentWidth: contentWidth,
            viewportWidth: viewportWidth,
            minimumHeight: minimumHeight,
            highlightsWords: highlightsWords,
            selectedRowIDs: selectedRowIDs,
            searchMatchIDs: searchMatchIDs,
            currentSearchMatchID: currentSearchMatchID,
            onExpand: onExpand,
            rowOverlay: { _, _ in EmptyView() }
        )
    }
}

private struct DiffSideRowView: View {
    let row: DiffRow
    let kind: DiffRowKind
    let side: DiffSide
    let fileExtension: String
    let highlightsWords: Bool
    let isSelectedDifference: Bool
    let isSearchMatch: Bool
    let isCurrentSearchMatch: Bool

    var body: some View {
        if kind == .information {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10))
                Text(row.left ?? "")
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(LitheTheme.diffInformationText)
            .padding(.horizontal, 12)
            .frame(height: DiffLayoutMetrics.informationRowHeight)
            .frame(maxWidth: .infinity)
            .background(LitheTheme.diffInformationBackground)
            .overlay(searchMatchOverlay)
        } else {
            HStack(spacing: 0) {
                Text(lineNumber.map(String.init) ?? "")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(lineNumberColor)
                    .frame(width: DiffLayoutMetrics.lineNumberColumnWidth, alignment: .trailing)
                    .padding(.trailing, DiffLayoutMetrics.lineNumberTrailingPadding)
                    .frame(maxHeight: .infinity)
                    .background(LitheTheme.window.opacity(0.62))

                Rectangle()
                    .fill(changeMarkerColor)
                    .frame(width: DiffLayoutMetrics.changeMarkerWidth)

                Text(
                    DiffSyntaxHighlighter.styled(
                        text,
                        comparing: otherText,
                        fileExtension: fileExtension,
                        side: side,
                        highlightsWords: highlightsWords && kind == .changed
                    )
                )
                .font(.system(size: DiffLayoutMetrics.textFontSize, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DiffLayoutMetrics.textHorizontalPadding)
            }
            .frame(height: DiffLayoutMetrics.rowHeight)
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .overlay(alignment: .leading) {
                if isSelectedDifference {
                    Rectangle().fill(LitheTheme.accent).frame(width: 2)
                }
            }
            .overlay(searchMatchOverlay)
        }
    }

    private var text: String {
        switch side {
        case .left: row.left ?? ""
        case .right: row.rightText ?? ""
        }
    }

    private var otherText: String? {
        switch side {
        case .left: row.rightText
        case .right: row.left
        }
    }

    private var lineNumber: Int? {
        switch side {
        case .left: row.oldLine
        case .right: row.newLine
        }
    }

    private var backgroundColor: Color {
        let selectionBoost = isSelectedDifference ? 0.04 : 0
        let searchBoost = isSearchMatch ? 0.04 : 0
        switch kind {
        case .changed:
            return side == .left
                ? LitheTheme.error.opacity(0.22 + selectionBoost + searchBoost)
                : LitheTheme.success.opacity(0.24 + selectionBoost + searchBoost)
        case .removal where side == .left:
            return LitheTheme.error.opacity(0.27 + selectionBoost + searchBoost)
        case .addition where side == .right:
            return LitheTheme.success.opacity(0.27 + selectionBoost + searchBoost)
        default:
            return .clear
        }
    }

    private var changeMarkerColor: Color {
        switch kind {
        case .addition where side == .right:
            return LitheTheme.success.opacity(0.72)
        case .removal where side == .left:
            return LitheTheme.error.opacity(0.72)
        case .changed:
            return side == .left
                ? LitheTheme.error.opacity(0.64)
                : LitheTheme.success.opacity(0.64)
        default:
            return .clear
        }
    }

    private var lineNumberColor: Color {
        switch kind {
        case .addition where side == .right: LitheTheme.success.opacity(0.75)
        case .removal where side == .left: LitheTheme.error.opacity(0.74)
        default: LitheTheme.secondaryText.opacity(0.78)
        }
    }

    @ViewBuilder
    private var searchMatchOverlay: some View {
        if isCurrentSearchMatch {
            Rectangle().stroke(Color.yellow.opacity(0.88), lineWidth: 1)
        }
    }
}

private struct DiffTransitionOverlay: View {
    let transitions: [DiffSplitLayout.Transition]
    let contentWidth: CGFloat
    let contentHeight: CGFloat

    var body: some View {
        let paneWidth = max(0, (contentWidth - DiffLayoutMetrics.centerGutterWidth) / 2)
        let gutterEnd = paneWidth + DiffLayoutMetrics.centerGutterWidth

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for transition in transitions {
                    let color = transitionColor(transition)
                    let path = connectorPath(
                        transition,
                        leftX: paneWidth,
                        rightX: gutterEnd
                    )
                    context.fill(path, with: .color(color.opacity(0.18)))
                    context.stroke(
                        path,
                        with: .color(color.opacity(0.50)),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                    )

                    if transition.isAddition {
                        drawInsertionRule(
                            in: &context,
                            fromX: 0,
                            toX: paneWidth,
                            y: transition.leftRange.lowerBound,
                            color: LitheTheme.success
                        )
                    } else if transition.isRemoval {
                        drawInsertionRule(
                            in: &context,
                            fromX: gutterEnd,
                            toX: contentWidth,
                            y: transition.rightRange.lowerBound,
                            color: LitheTheme.error
                        )
                    }
                }
            }

            ForEach(transitions) { transition in
                Image(systemName: transitionSymbol(transition))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(transitionColor(transition).opacity(0.88))
                    .frame(width: DiffLayoutMetrics.centerGutterWidth, height: 14)
                    .offset(x: paneWidth, y: transitionMarkerY(transition) - 7)
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func connectorPath(
        _ transition: DiffSplitLayout.Transition,
        leftX: CGFloat,
        rightX: CGFloat
    ) -> Path {
        let controlX1 = leftX + (rightX - leftX) * 0.42
        let controlX2 = leftX + (rightX - leftX) * 0.58
        var path = Path()
        path.move(to: CGPoint(x: leftX, y: transition.leftRange.lowerBound))
        path.addCurve(
            to: CGPoint(x: rightX, y: transition.rightRange.lowerBound),
            control1: CGPoint(x: controlX1, y: transition.leftRange.lowerBound),
            control2: CGPoint(x: controlX2, y: transition.rightRange.lowerBound)
        )
        path.addLine(to: CGPoint(x: rightX, y: transition.rightRange.upperBound))
        path.addCurve(
            to: CGPoint(x: leftX, y: transition.leftRange.upperBound),
            control1: CGPoint(x: controlX2, y: transition.rightRange.upperBound),
            control2: CGPoint(x: controlX1, y: transition.leftRange.upperBound)
        )
        path.closeSubpath()
        return path
    }

    private func drawInsertionRule(
        in context: inout GraphicsContext,
        fromX: CGFloat,
        toX: CGFloat,
        y: CGFloat,
        color: Color
    ) {
        let y = max(0.5, min(contentHeight - 0.5, y))
        var line = Path()
        line.move(to: CGPoint(x: fromX + 4, y: y))
        line.addLine(to: CGPoint(x: toX, y: y))
        context.stroke(
            line,
            with: .color(color.opacity(0.66)),
            style: StrokeStyle(lineWidth: 1, lineCap: .round)
        )
    }

    private func transitionColor(_ transition: DiffSplitLayout.Transition) -> Color {
        if transition.isRemoval { return LitheTheme.error }
        return LitheTheme.success
    }

    private func transitionSymbol(_ transition: DiffSplitLayout.Transition) -> String {
        if transition.isAddition { return "chevron.right" }
        if transition.isRemoval { return "chevron.left" }
        return "arrow.left.arrow.right"
    }

    private func transitionMarkerY(_ transition: DiffSplitLayout.Transition) -> CGFloat {
        if transition.isAddition { return transition.leftRange.lowerBound }
        if transition.isRemoval { return transition.rightRange.lowerBound }
        return min(
            (transition.leftRange.lowerBound + transition.leftRange.upperBound) / 2,
            (transition.rightRange.lowerBound + transition.rightRange.upperBound) / 2
        )
    }
}
