import SwiftUI
import LitheGitModule

/// Presentation only: replacements show the existing old row then the existing new row.
/// No comparison, navigation ID, or repository state is changed by the viewer toggle.
struct DiffUnifiedLayout {
    let identity = UUID()
    let items: [DiffSplitLayout.Item]
    let height: CGFloat
    let stripeLayout: DiffSplitLayout

    init(rows: [DiffRow], displayRows: [DiffDisplayRow]? = nil) {
        var items: [DiffSplitLayout.Item] = []
        var top: CGFloat = 0
        for display in displayRows ?? rows.enumerated().map({ .row($0.element, index: $0.offset) }) {
            if case .collapsed = display {
                items.append(.init(displayRow: display, kind: .information, top: top,
                    height: DiffLayoutMetrics.informationRowHeight, isScrollAnchor: false))
                top += DiffLayoutMetrics.informationRowHeight
                continue
            }
            guard case let .row(row, index) = display, row.kind != .information else { continue }
            let kinds: [DiffRowKind] = row.kind == .changed ? [.removal, .addition] : [row.kind]
            for (part, kind) in kinds.enumerated() {
                items.append(.init(displayRow: .row(row, index: index), kind: kind, top: top,
                    height: DiffLayoutMetrics.rowHeight, isScrollAnchor: part == 0))
                top += DiffLayoutMetrics.rowHeight
            }
        }
        self.items = items; height = top
        let transitions = items.filter { $0.kind.isSplitDifference }.map {
            DiffSplitLayout.Transition(id: "\($0.id)-\($0.top)", kind: $0.kind,
                leftRange: $0.top...($0.top + $0.height), rightRange: $0.top...($0.top + $0.height))
        }
        stripeLayout = DiffSplitLayout(leftItems: items, rightItems: items,
            transitions: transitions, leftHeight: top, rightHeight: top,
            lineNumberGutterWidth: DiffLayoutMetrics.lineNumberGutterWidth(rows: rows))
    }
}

struct DiffUnifiedPaneView: View {
    let layout: DiffUnifiedLayout
    let fileExtension: String
    let contentWidth: CGFloat
    let highlightsWords: Bool
    let selectedRowIDs: Set<DiffRowID>
    var onExpand: (DiffCollapsedRegion) -> Void = { _ in }
    @StateObject private var text = DiffNativeColumnState()
    @StateObject private var synchronization = DiffScrollSynchronization()

    var body: some View {
        synchronization.configure(layout.stripeLayout)
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        DiffNativeLineNumbers(state: text, showsBothNumbers: true)
                            .frame(width: layout.stripeLayout.lineNumberGutterWidth * 2,
                                   height: max(layout.height, geometry.size.height))
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                DiffNativeCodeColumn(state: text, layoutIdentity: layout.identity,
                                    items: layout.items, side: .right, fileExtension: fileExtension,
                                    highlightsWords: highlightsWords, selectedRowIDs: selectedRowIDs,
                                    currentSearchMatchID: nil, unified: true)
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(layout.items.enumerated()), id: \.offset) { _, item in
                                        if case let .collapsed(region) = item.displayRow {
                                            DiffCollapsedBandView(region: region, contentWidth: max(geometry.size.width, contentWidth)) {
                                                onExpand(region)
                                            }
                                        } else if item.isScrollAnchor {
                                            Color.clear.frame(height: item.height)
                                                .id(item.displayRow.layoutRow.id).allowsHitTesting(false)
                                        } else { Color.clear.frame(height: item.height).allowsHitTesting(false) }
                                    }
                                }
                            }.frame(width: max(geometry.size.width, contentWidth),
                                    height: max(layout.height, geometry.size.height), alignment: .topLeading)
                        }.litheScrollViewChrome(hideHorizontal: false)
                    }.background { DiffScrollAttachment(synchronization: synchronization, side: .right) }
                }
                DiffErrorStripe(synchronization: synchronization, side: .right).frame(width: LitheScrollBarStyle.editorThickness, height: geometry.size.height)
            }
        }.background(LitheTheme.Diff.background)
    }
}
