import SwiftUI
import LitheGitModule

/// IDEA-style side-by-side diff whose two code panes advance independently.
/// One-sided changes therefore never manufacture blank source rows; their
/// height difference is explained by the curved transition in the gutter.
struct DiffSplitPaneView<RowOverlay: View>: View {
    let layout: DiffSplitLayout
    let fileExtension: String
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let highlightsWords: Bool
    let selectedRowIDs: Set<DiffRowID>
    let searchMatchIDs: Set<DiffRowID>
    let currentSearchMatchID: DiffRowID?
    let onExpand: (DiffCollapsedRegion) -> Void
    let rowOverlay: (DiffRow, DiffSide) -> RowOverlay

    @State private var leftPaneWidth: CGFloat?
    @StateObject private var leftText = DiffNativeColumnState()
    @StateObject private var rightText = DiffNativeColumnState()
    @State private var paneDragStart: CGFloat = 0

    init(
        displayRows: [DiffDisplayRow],
        kinds: [DiffRowKind],
        layout: DiffSplitLayout? = nil,
        fileExtension: String,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        highlightsWords: Bool = true,
        selectedRowIDs: Set<DiffRowID> = [],
        searchMatchIDs: Set<DiffRowID> = [],
        currentSearchMatchID: DiffRowID? = nil,
        onExpand: @escaping (DiffCollapsedRegion) -> Void,
        @ViewBuilder rowOverlay: @escaping (DiffRow, DiffSide) -> RowOverlay
    ) {
        self.layout = layout ?? DiffSplitLayout.plan(displayRows: displayRows, kinds: kinds)
        self.fileExtension = fileExtension
        self.contentWidth = contentWidth
        self.viewportWidth = viewportWidth
        self.highlightsWords = highlightsWords
        self.selectedRowIDs = selectedRowIDs
        self.searchMatchIDs = searchMatchIDs
        self.currentSearchMatchID = currentSearchMatchID
        self.onExpand = onExpand
        self.rowOverlay = rowOverlay
    }

    var body: some View {
        let panes = DiffSplitWidths(width: viewportWidth, position: leftPaneWidth)
        let paneViewportWidth = panes.leftCode
        let rightPaneViewportWidth = panes.rightCode
        // Code storage has a stable width. Resizing only changes its clipping rectangle.
        let paneContentWidth = max(viewportWidth, (contentWidth - DiffLayoutMetrics.centerGutterWidth) / 2)
        let leftColumn = sideColumn(layout.leftItems, side: .left, width: paneContentWidth, accessoryWidth: paneViewportWidth, state: leftText)
        let rightColumn = sideColumn(layout.rightItems, side: .right, width: paneContentWidth, accessoryWidth: rightPaneViewportWidth, state: rightText)
        let horizontalOverflow = max(0, (contentWidth - DiffLayoutMetrics.centerGutterWidth) / 2
            - min(paneViewportWidth, rightPaneViewportWidth))
        return GeometryReader { geometry in
            let height = max(layout.contentHeight, geometry.size.height)
            DiffHorizontalOffsetLayer(
                viewportWidth: viewportWidth,
                contentWidth: viewportWidth + horizontalOverflow,
                height: height
            ) { horizontalOffset in
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 0) {
                        sideViewport(
                            leftColumn,
                            viewportWidth: paneViewportWidth,
                            height: height,
                            horizontalOffset: horizontalOffset
                        )
                        lineNumbers(side: .left, state: leftText)
                            .frame(width: panes.leftNumbers, alignment: .trailing).clipped()
                        LitheTheme.Diff.background.frame(width: panes.divider)
                        lineNumbers(side: .right, state: rightText)
                            .frame(width: panes.rightNumbers, alignment: .leading).clipped()
                        sideViewport(
                            rightColumn,
                            viewportWidth: rightPaneViewportWidth,
                            height: height,
                            horizontalOffset: horizontalOffset
                        )
                    }

                    DiffTransitionOverlay(
                        transitions: layout.transitions,
                        leftPaneWidth: paneViewportWidth + panes.leftNumbers - DiffLayoutMetrics.lineNumberGutterWidth,
                        dividerWidth: panes.divider
                    ).frame(width: viewportWidth, height: height).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                SplitHandleView(
                    axis: .horizontal,
                    showsIdleDivider: false,
                    highlightsOnHover: false,
                    onDragStarted: {
                        paneDragStart = panes.position
                    },
                    onDragChanged: { translation in
                        leftPaneWidth = min(max(paneDragStart + translation, 0), viewportWidth)
                    },
                    onDragEnded: { translation in
                        leftPaneWidth = min(max(paneDragStart + translation, 0), viewportWidth)
                    }
                )
                .offset(x: min(max(panes.position - SplitHandleView.thickness / 2, 0), max(0, viewportWidth - SplitHandleView.thickness)))
                .frame(height: geometry.size.height)
            }
            .frame(width: viewportWidth, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func sideViewport<Column: View>(
        _ column: Column,
        viewportWidth: CGFloat,
        height: CGFloat,
        horizontalOffset: CGFloat
    ) -> some View {
        column
            .offset(x: -horizontalOffset)
            .frame(width: viewportWidth, height: height, alignment: .topLeading)
            .clipped()
            .background(LitheTheme.Diff.background)
    }

    private func lineNumbers(side: DiffSide,
                             state: DiffNativeColumnState) -> some View {
        DiffNativeLineNumbers(state: state)
            .frame(width: DiffLayoutMetrics.lineNumberGutterWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityLabel(side == .left ? "Original line numbers" : "Modified line numbers")
            .overlay(alignment: side == .left ? .leading : .trailing) {
                Rectangle().fill(LitheTheme.Diff.separator).frame(width: 1)
            }
    }

    private func sideColumn(_ items: [DiffSplitLayout.Item], side: DiffSide, width: CGFloat,
                            accessoryWidth: CGFloat, state: DiffNativeColumnState) -> some View {
        ZStack(alignment: .topLeading) {
            DiffNativeCodeColumn(state: state, layoutIdentity: layout.identity, items: items,
                side: side, fileExtension: fileExtension, highlightsWords: highlightsWords,
                selectedRowIDs: selectedRowIDs, currentSearchMatchID: currentSearchMatchID)
                .frame(width: width, height: layout.contentHeight)
            // Retain existing fold/hunk actions and ScrollViewReader anchors. Normal
            // rows are transparent hit-test-free geometry, not separate text editors.
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    if item.isScrollAnchor {
                        sideAccessory(item, side: side, width: accessoryWidth).id(item.displayRow.layoutRow.id)
                    } else {
                        sideAccessory(item, side: side, width: accessoryWidth)
                    }
                }
            }.frame(width: accessoryWidth, alignment: .leading)
        }.frame(width: width, alignment: .topLeading)
    }

    @ViewBuilder
    private func sideAccessory(_ item: DiffSplitLayout.Item, side: DiffSide, width: CGFloat) -> some View {
        Group {
            if case let .collapsed(region) = item.displayRow {
                DiffCollapsedBandView(region: region, contentWidth: width) { onExpand(region) }
            } else if case let .row(row, _) = item.displayRow {
                if item.kind == .information {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease").font(LitheTheme.uiFont(size: 10))
                        Text(row.left ?? "").font(LitheTheme.uiFont(size: 11.5, design: .monospaced)).lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(LitheTheme.diffInformationText).padding(.horizontal, 12)
                    .frame(height: item.height)
                    .background(LitheTheme.Diff.separator)
                } else {
                    Color.clear.allowsHitTesting(false)
                }
            }
        }.frame(width: width, height: item.height)
            .overlay(alignment: .topTrailing) {
                if case let .row(row, _) = item.displayRow { rowOverlay(row, side) }
            }
    }


}

/// Owns the high-frequency horizontal scroll state below the diff layout
/// owner. Updating the offset therefore does not re-evaluate
/// `DiffSplitLayout.plan` or the pane-resizing state in `DiffSplitPaneView`.
private struct DiffHorizontalOffsetLayer<Content: View>: View {
    let viewportWidth: CGFloat
    let contentWidth: CGFloat
    let height: CGFloat
    let content: (CGFloat) -> Content

    @State private var horizontalOffset: CGFloat = 0
    @State private var wheelScheduler = LitheDragUpdateScheduler()

    init(
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        height: CGFloat,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.viewportWidth = viewportWidth
        self.contentWidth = contentWidth
        self.height = height
        self.content = content
    }

    private var maximumHorizontalOffset: CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                content(horizontalOffset)
                    .frame(width: viewportWidth, height: height, alignment: .topLeading)
            }
            .litheScrollViewChrome(hideHorizontal: true)

            DiffHorizontalScroller(
                offset: $horizontalOffset,
                viewportWidth: viewportWidth,
                contentWidth: contentWidth
            )
        }
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
        .onChange(of: maximumHorizontalOffset) { newMaximum in
            wheelScheduler.cancel()
            horizontalOffset = min(horizontalOffset, newMaximum)
        }
        .onDisappear { wheelScheduler.cancel() }
    }
}

extension DiffSplitPaneView where RowOverlay == EmptyView {
    init(
        displayRows: [DiffDisplayRow],
        kinds: [DiffRowKind],
        layout: DiffSplitLayout? = nil,
        fileExtension: String,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        highlightsWords: Bool = true,
        selectedRowIDs: Set<DiffRowID> = [],
        searchMatchIDs: Set<DiffRowID> = [],
        currentSearchMatchID: DiffRowID? = nil,
        onExpand: @escaping (DiffCollapsedRegion) -> Void
    ) {
        self.init(
            displayRows: displayRows,
            kinds: kinds,
            layout: layout,
            fileExtension: fileExtension,
            contentWidth: contentWidth,
            viewportWidth: viewportWidth,
            highlightsWords: highlightsWords,
            selectedRowIDs: selectedRowIDs,
            searchMatchIDs: searchMatchIDs,
            currentSearchMatchID: currentSearchMatchID,
            onExpand: onExpand,
            rowOverlay: { _, _ in EmptyView() }
        )
    }
}

private struct DiffTransitionOverlay: NSViewRepresentable {
    let transitions: [DiffSplitLayout.Transition]
    let leftPaneWidth: CGFloat
    var dividerWidth: CGFloat = DiffLayoutMetrics.dividerWidth

    func makeNSView(context: Context) -> DiffNativeTransitionsView { DiffNativeTransitionsView() }
    func updateNSView(_ view: DiffNativeTransitionsView, context: Context) {
        view.transitions = transitions
        view.leftX = leftPaneWidth + DiffLayoutMetrics.lineNumberGutterWidth
        view.rightX = view.leftX + dividerWidth
        view.needsDisplay = true
    }
}
