import SwiftUI
import LitheGitModule

/// Presentation only: replacements show the existing old row then the existing new row.
/// No comparison, navigation ID, or repository state is changed by the viewer toggle.
struct DiffUnifiedLayout {
    let identity = UUID()
    let items: [DiffSplitLayout.Item]
    let height: CGFloat
    let stripeLayout: DiffSplitLayout

    init(rows: [DiffRow]) {
        var items: [DiffSplitLayout.Item] = []
        var top: CGFloat = 0
        for (index, row) in rows.enumerated() where row.kind != .information {
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
            transitions: transitions, leftHeight: top, rightHeight: top)
    }
}

struct DiffUnifiedPaneView: View {
    let layout: DiffUnifiedLayout
    let fileExtension: String
    let contentWidth: CGFloat
    let highlightsWords: Bool
    let selectedRowIDs: Set<DiffRowID>
    @StateObject private var text = DiffNativeColumnState()
    @StateObject private var synchronization = DiffScrollSynchronization()

    var body: some View {
        synchronization.configure(layout.stripeLayout)
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        DiffNativeLineNumbers(state: text, showsBothNumbers: true)
                            .frame(width: DiffLayoutMetrics.lineNumberGutterWidth * 2,
                                   height: max(layout.height, geometry.size.height))
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(LitheTheme.Diff.separator).frame(width: 1)
                            }
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                DiffNativeCodeColumn(state: text, layoutIdentity: layout.identity,
                                    items: layout.items, side: .right, fileExtension: fileExtension,
                                    highlightsWords: highlightsWords, selectedRowIDs: selectedRowIDs,
                                    currentSearchMatchID: nil, unified: true)
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(layout.items.enumerated()), id: \.offset) { _, item in
                                        if item.isScrollAnchor {
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
                DiffErrorStripe(synchronization: synchronization, side: .right).frame(width: DiffMapView.width, height: geometry.size.height)
            }
        }.background(LitheTheme.Diff.background)
    }
}
