import SwiftUI
import LitheGitModule

/// Shared side-by-side diff surface.
///
/// `DiffReviewView`, `LocalHistoryView`, `ProjectLocalHistoryView` and
/// `BranchComparisonView` all needed the same four things: measure the widest
/// line, size the canvas past the viewport so long lines stay reachable, draw
/// the connector ribbons underneath, and lay the rows out in a `LazyVStack`.
/// Keeping one copy means the collapse affordance and the horizontal-scroll
/// metrics only have to be taught to a single view.
struct DiffPaneView: View {
    let rows: [DiffRow]
    let fileExtension: String
    var minimumWidth: CGFloat = 900
    var highlightsWords: Bool = true
    var collapsesUnchangedRegions: Bool = true
    var showsDiffMap: Bool = true

    @State private var expandedRegionIDs: Set<String> = []
    @State private var pinnedRowIDs: Set<DiffRowID> = []

    var body: some View {
        HStack(spacing: 0) {
            diffSurface
            if showsDiffMap, !rows.isEmpty {
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                DiffMapView(rows: rows) { rowID in
                    // A tick can point into a fold, so force that region open
                    // before asking the list to scroll there.
                    pinnedRowIDs = [rowID]
                    scrollTarget = rowID
                }
            }
        }
        .onChange(of: rows.map(\.id)) { _ in
            expandedRegionIDs.removeAll()
            pinnedRowIDs.removeAll()
            scrollTarget = nil
        }
    }

    @State private var scrollTarget: DiffRowID?

    private var diffSurface: some View {
        GeometryReader { geometry in
            let displayRows = displayRows()
            let contentWidth = DiffLayoutMetrics.contentWidth(
                rows: rows,
                viewportWidth: geometry.size.width,
                minimumWidth: minimumWidth,
                paneCount: 2
            )
            let kinds = displayRows.map { displayRow in
                switch displayRow {
                case let .row(row, _): row.kind
                case .collapsed: DiffRowKind.information
                }
            }

            ScrollViewReader { proxy in
                DiffSplitPaneView(
                    displayRows: displayRows,
                    kinds: kinds,
                    fileExtension: fileExtension,
                    contentWidth: contentWidth,
                    viewportWidth: geometry.size.width,
                    minimumHeight: geometry.size.height,
                    highlightsWords: highlightsWords
                ) { region in
                    expandedRegionIDs.insert(region.id)
                }
                .onChange(of: scrollTarget) { target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    private func displayRows() -> [DiffDisplayRow] {
        guard collapsesUnchangedRegions else {
            return rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        }
        return DiffCollapse.plan(
            rows: rows,
            expandedRegionIDs: expandedRegionIDs,
            pinnedRowIDs: pinnedRowIDs
        )
    }
}
