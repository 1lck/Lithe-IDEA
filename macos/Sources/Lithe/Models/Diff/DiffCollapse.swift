import Foundation
import LitheGitModule

/// A run of unchanged rows folded into a single clickable band.
struct DiffCollapsedRegion: Identifiable, Hashable {
    /// Stable across re-parses because it is derived from the row range rather
    /// than allocated, so an expanded region stays expanded after a refresh.
    let id: String
    /// Index of the first hidden row in the source row list.
    let startIndex: Int
    /// Index one past the last hidden row.
    let endIndex: Int

    var hiddenRowCount: Int { endIndex - startIndex }
}

/// One entry in the rendered list: either a real diff row or a collapse band.
enum DiffDisplayRow: Identifiable {
    /// Carries the row's index in the source list so callers can keep using
    /// their own per-index lookups (effective kind, difference numbering).
    case row(DiffRow, index: Int)
    case collapsed(DiffCollapsedRegion)

    var id: String {
        switch self {
        case let .row(row, _):
            return "row-\(row.id.hunkID ?? "-")-\(row.id.oldLine ?? -1)-\(row.id.newLine ?? -1)-\(row.id.sequence)"
        case let .collapsed(region):
            return region.id
        }
    }

    /// Row used for layout measurement. A band measures like an information
    /// row, which is what the `@@` separators already are, so the existing
    /// height and connector math needs no special case.
    var layoutRow: DiffRow {
        switch self {
        case let .row(row, _):
            return row
        case let .collapsed(region):
            return DiffRow(
                oldLine: nil,
                newLine: nil,
                left: nil,
                right: nil,
                kind: .information,
                sequence: region.startIndex
            )
        }
    }
}

enum DiffCollapse {
    /// Runs shorter than this stay expanded: hiding four lines to save three
    /// costs more than it returns.
    static let defaultThreshold = 12
    /// Unchanged lines kept visible on each side of a fold, so a change never
    /// appears without its immediate surroundings.
    static let defaultContextLines = 3

    /// Folds long runs of unchanged rows, leaving `contextLines` visible on
    /// each side. Regions listed in `expandedRegionIDs` are emitted in full, as
    /// is any region containing a row in `pinnedRowIDs` — otherwise a search hit
    /// or a difference-navigation target could land inside a fold and the view
    /// would scroll to a row that is not rendered.
    static func plan(
        rows: [DiffRow],
        expandedRegionIDs: Set<String> = [],
        pinnedRowIDs: Set<DiffRowID> = [],
        threshold: Int = defaultThreshold,
        contextLines: Int = defaultContextLines
    ) -> [DiffDisplayRow] {
        guard !rows.isEmpty else { return [] }

        var display: [DiffDisplayRow] = []
        var index = 0

        func appendRows(_ range: Range<Int>) {
            for index in range {
                display.append(.row(rows[index], index: index))
            }
        }

        while index < rows.count {
            guard isFoldable(rows[index]) else {
                display.append(.row(rows[index], index: index))
                index += 1
                continue
            }

            var runEnd = index
            while runEnd < rows.count, isFoldable(rows[runEnd]) {
                runEnd += 1
            }

            let leadingContext = index == 0 ? 0 : contextLines
            let trailingContext = runEnd == rows.count ? 0 : contextLines
            let hiddenStart = index + leadingContext
            let hiddenEnd = runEnd - trailingContext
            let hiddenCount = hiddenEnd - hiddenStart
            let region = DiffCollapsedRegion(
                id: "collapsed-\(hiddenStart)-\(hiddenEnd)",
                startIndex: hiddenStart,
                endIndex: hiddenEnd
            )

            let containsPinnedRow = !pinnedRowIDs.isEmpty
                && rows[hiddenStart..<max(hiddenStart, hiddenEnd)].contains { pinnedRowIDs.contains($0.id) }

            if hiddenCount < threshold || expandedRegionIDs.contains(region.id) || containsPinnedRow {
                appendRows(index..<runEnd)
            } else {
                appendRows(index..<hiddenStart)
                display.append(.collapsed(region))
                appendRows(hiddenEnd..<runEnd)
            }

            index = runEnd
        }

        return display
    }

    /// `information` rows are the `@@` separators; folding them away would hide
    /// the hunk boundaries that orient the reader.
    private static func isFoldable(_ row: DiffRow) -> Bool {
        row.kind == .context
    }
}
