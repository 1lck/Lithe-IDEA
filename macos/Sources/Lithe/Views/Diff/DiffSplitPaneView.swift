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
    let showsChangeMarkers: Bool
    let header: ((CGFloat) -> AnyView)?
    let selectedRowIDs: Set<DiffRowID>
    let searchMatchIDs: Set<DiffRowID>
    let currentSearchMatchID: DiffRowID?
    let onExpand: (DiffCollapsedRegion) -> Void
    let rowOverlay: (DiffRow, DiffSide) -> RowOverlay

    @StateObject private var synchronization = DiffScrollSynchronization()
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
        showsChangeMarkers: Bool = true,
        header: ((CGFloat) -> AnyView)? = nil,
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
        self.showsChangeMarkers = showsChangeMarkers
        self.header = header
        self.selectedRowIDs = selectedRowIDs
        self.searchMatchIDs = searchMatchIDs
        self.currentSearchMatchID = currentSearchMatchID
        self.onExpand = onExpand
        self.rowOverlay = rowOverlay
    }

    var body: some View {
        synchronization.configure(layout)
        let panes = DiffSplitWidths(width: viewportWidth, position: leftPaneWidth, gutterWidth: layout.lineNumberGutterWidth)
        let leftStripeWidth = showsChangeMarkers ? min(LitheScrollBarStyle.editorThickness, panes.leftCode) : 0
        let rightStripeWidth = showsChangeMarkers ? min(LitheScrollBarStyle.editorThickness, panes.rightCode) : 0
        let paneViewportWidth = panes.leftCode
        let rightPaneViewportWidth = panes.rightCode
        // Code storage has a stable width. Resizing only changes its clipping rectangle.
        let centerGutterWidth = layout.lineNumberGutterWidth * 2 + DiffLayoutMetrics.dividerWidth
        let paneContentWidth = max(viewportWidth, (contentWidth - centerGutterWidth) / 2)
        let leftColumn = sideColumn(layout.leftItems, side: .left, width: paneContentWidth, accessoryWidth: paneViewportWidth - leftStripeWidth, state: leftText)
        let rightColumn = sideColumn(layout.rightItems, side: .right, width: paneContentWidth, accessoryWidth: rightPaneViewportWidth - rightStripeWidth, state: rightText)
        let horizontalOverflow = max(0, (contentWidth - centerGutterWidth) / 2
            - min(paneViewportWidth - leftStripeWidth, rightPaneViewportWidth - rightStripeWidth))
        return VStack(spacing: 0) {
            if let header { header(panes.position) }
            GeometryReader { geometry in
                let height = max(layout.contentHeight, geometry.size.height)
                DiffHorizontalOffsetLayer(
                    viewportWidth: viewportWidth,
                    contentWidth: viewportWidth + horizontalOverflow
                ) { horizontalOffset in
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 0) {
                            DiffErrorStripe(synchronization: synchronization, side: .left)
                                .frame(width: leftStripeWidth, height: geometry.size.height)
                            ScrollView(.vertical, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 0) {
                                    sideViewport(leftColumn, viewportWidth: panes.leftCode - leftStripeWidth,
                                        height: height, horizontalOffset: horizontalOffset)
                                    lineNumbers(side: .left, state: leftText)
                                        .frame(width: panes.leftNumbers, alignment: .trailing).clipped()
                                }
                                .background { DiffScrollAttachment(synchronization: synchronization, side: .left) }
                            }.frame(width: panes.leftCode - leftStripeWidth + panes.leftNumbers)
                            LitheTheme.Diff.background.frame(width: panes.divider)
                            ScrollView(.vertical, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 0) {
                                    lineNumbers(side: .right, state: rightText)
                                        .frame(width: panes.rightNumbers, alignment: .leading).clipped()
                                    sideViewport(rightColumn, viewportWidth: panes.rightCode - rightStripeWidth,
                                        height: height, horizontalOffset: horizontalOffset)
                                }
                                .background { DiffScrollAttachment(synchronization: synchronization, side: .right) }
                            }.frame(width: panes.rightNumbers + panes.rightCode - rightStripeWidth)
                            DiffErrorStripe(synchronization: synchronization, side: .right)
                                .frame(width: rightStripeWidth, height: geometry.size.height)
                        }
                        DiffTransitionOverlay(
                            transitions: layout.transitions,
                            leftX: panes.leftCode + panes.leftNumbers,
                            dividerWidth: panes.divider,
                            synchronization: synchronization
                        ).frame(width: viewportWidth, height: geometry.size.height).allowsHitTesting(false)
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
        DiffNativeLineNumbers(state: state, mirrored: side == .left)
            .frame(width: layout.lineNumberGutterWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityLabel(side == .left ? "Original line numbers" : "Modified line numbers")
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
    let content: (CGFloat) -> Content

    @State private var horizontalOffset: CGFloat = 0
    @State private var wheelScheduler = LitheDragUpdateScheduler()

    init(
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.viewportWidth = viewportWidth
        self.contentWidth = contentWidth
        self.content = content
    }

    private var maximumHorizontalOffset: CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content(horizontalOffset)

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
        showsChangeMarkers: Bool = true,
        header: ((CGFloat) -> AnyView)? = nil,
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
            showsChangeMarkers: showsChangeMarkers,
            header: header,
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
    let leftX: CGFloat
    var dividerWidth: CGFloat = DiffLayoutMetrics.dividerWidth
    let synchronization: DiffScrollSynchronization

    func makeNSView(context: Context) -> DiffNativeTransitionsView { DiffNativeTransitionsView() }
    func updateNSView(_ view: DiffNativeTransitionsView, context: Context) {
        synchronization.transitionsView = view
        synchronization.refresh()
        view.transitions = transitions
        view.leftX = leftX
        view.rightX = view.leftX + dividerWidth
        view.needsDisplay = true
    }
}
