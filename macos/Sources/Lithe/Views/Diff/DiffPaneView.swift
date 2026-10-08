import SwiftUI
import LitheGitModule

/// Shared side-by-side diff surface.
///
/// `LocalHistoryView`, `ProjectLocalHistoryView` and
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
    var fontFamily: String = EditorFontDefaults.monospacedFamily

    @State private var expandedRegionIDs: Set<String> = []
    var body: some View {
        diffSurface
            .onChange(of: rows.map(\.id)) { _ in expandedRegionIDs.removeAll() }
    }

    private var diffSurface: some View {
        let displayRows = displayRows()
        let measuredWidth = DiffLayoutMetrics.contentWidth(
            rows: rows, viewportWidth: 0, minimumWidth: minimumWidth, paneCount: 2, family: fontFamily)
        let kinds = displayRows.map { displayRow in
            switch displayRow {
            case let .row(row, _): row.kind
            case .collapsed: DiffRowKind.information
            }
        }
        let layout = DiffSplitLayout.plan(displayRows: displayRows, kinds: kinds, gutterWidth: DiffLayoutMetrics.lineNumberGutterWidth(rows: rows, family: fontFamily))
        return GeometryReader { geometry in
            let contentWidth = max(geometry.size.width, measuredWidth)

            ScrollViewReader { _ in
                DiffSplitPaneView(
                    displayRows: displayRows,
                    kinds: kinds,
                    layout: layout,
                    fileExtension: fileExtension,
                    contentWidth: contentWidth,
                    viewportWidth: geometry.size.width,
                    highlightsWords: highlightsWords,
                    showsChangeMarkers: showsDiffMap,
                    fontFamily: fontFamily
                ) { region in
                    expandedRegionIDs.insert(region.id)
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
            expandedRegionIDs: expandedRegionIDs
        )
    }
}
