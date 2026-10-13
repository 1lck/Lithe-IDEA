import SwiftUI
import LitheGitModule

enum DiffLayoutMetrics {
    static let rowHeight: CGFloat = 22
    static let informationRowHeight: CGFloat = 27
    // Community registry diff.divider.width; DiffSplitter uses this logical width.
    static let dividerWidth: CGFloat = 24
    /// Bundled-family conveniences for call sites that have no font setting
    /// available and therefore keep rendering with the bundled monospaced family.
    static var lineNumberGutterWidth: CGFloat { lineNumberGutterWidth(maximumLine: 999) }
    static func lineNumberGutterWidth(
        rows: [DiffRow], family: String = EditorFontDefaults.monospacedFamily
    ) -> CGFloat {
        lineNumberGutterWidth(
            maximumLine: rows.reduce(1) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }, family: family)
    }
    static func lineNumberGutterWidth(
        maximumLine: Int, family: String = EditorFontDefaults.monospacedFamily
    ) -> CGFloat {
        // EditorGutterLayout New UI: empty annotations 4, pre-number gap 4,
        // number area (at least the 16pt breakpoint slot), post-number gap 4,
        // folding anchor 9 + 2, extra painter 8 + separator 1. Diff gutters
        // share the maximum source-number width; no action icon area is reserved.
        let number = ceil(NSAttributedString(string: String(maximumLine),
            attributes: [.font: MacEditorFontCatalog.font(family: family, size: textFontSize)]).size().width)
        return max(16, number) + lineNumberChromeWidth
    }
    static func centerGutterWidth(family: String) -> CGFloat {
        lineNumberGutterWidth(maximumLine: 999, family: family) * 2 + dividerWidth
    }
    /// Bundled-family convenience for the call sites without a font setting.
    static var centerGutterWidth: CGFloat {
        centerGutterWidth(family: EditorFontDefaults.monospacedFamily)
    }

    /// Line numbers are pinned on both sides of the central divider; only
    /// text insets scroll with each source pane.
    static let lineNumberColumnWidth: CGFloat = 47
    static let lineNumberTrailingPadding: CGFloat = 8
    static let lineNumberChromeWidth: CGFloat = 32
    static let gutterCodeEdgeWidth: CGFloat = 3
    static let changeMarkerWidth: CGFloat = 3
    static let textHorizontalPadding: CGFloat = 8
    static let textFontSize: CGFloat = 13

    static var paneChromeWidth: CGFloat {
        textHorizontalPadding * 2
    }

    /// Single-pane content reserves source line numbers alongside the code.
    static let singlePaneLineNumberColumnWidth: CGFloat = 55
    static let singlePaneLineNumberTrailingPadding: CGFloat = 9
    static let singlePaneTextHorizontalPadding: CGFloat = 10

    static var singlePaneChromeWidth: CGFloat {
        singlePaneLineNumberColumnWidth + singlePaneLineNumberTrailingPadding
            + changeMarkerWidth + singlePaneTextHorizontalPadding * 2
    }

    /// Advance of one character in the diff's monospaced font. Measured once per
    /// family because every glyph in a monospaced face shares the same advance.
    static var characterWidth: CGFloat {
        characterWidth(family: EditorFontDefaults.monospacedFamily)
    }

    static func characterWidth(family: String) -> CGFloat {
        let key = EditorFontResolution.normalizedFamily(family)
        characterWidthLock.lock()
        defer { characterWidthLock.unlock() }
        if let cached = characterWidthsByFamily[key] { return cached }

        let font = MacEditorFontCatalog.font(family: key, size: textFontSize, weight: .regular)
        let measured = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        let width = measured > 0 ? measured : textFontSize * 0.6
        characterWidthsByFamily[key] = width
        return width
    }

    /// Per-family cache for `characterWidth(family:)`. The metric is requested on
    /// every re-measure, and resolving a family into an `NSFont` is expensive.
    private static var characterWidthsByFamily: [String: CGFloat] = [:]
    private static let characterWidthLock = NSLock()

    static func rowHeight(for kind: DiffRowKind) -> CGFloat {
        kind == .information ? informationRowHeight : rowHeight
    }

    static func contentHeight(rows: [DiffRow], kinds: [DiffRowKind]) -> CGFloat {
        zip(rows, kinds).reduce(0) { height, pair in
            height + rowHeight(for: pair.1)
        }
    }

    /// Longest rendered line in either pane, in characters. Tabs count as four
    /// columns so tab-indented sources are not under-measured.
    static func longestLineLength(rows: [DiffRow]) -> Int {
        rows.reduce(0) { longest, row in
            max(longest, max(displayLength(row.left), displayLength(row.rightText)))
        }
    }

    private static func displayLength(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// Content width that lets the longest line scroll fully into view.
    ///
    /// Replaces the previous `max(fixedMinimum, viewportWidth)`, which never
    /// exceeded the viewport on wide windows and so left long lines truncated
    /// with no way to reach them.
    static func contentWidth(
        rows: [DiffRow],
        viewportWidth: CGFloat,
        minimumWidth: CGFloat,
        paneCount: Int,
        family: String = EditorFontDefaults.monospacedFamily
    ) -> CGFloat {
        let panes = CGFloat(max(1, paneCount))
        let textWidth = CGFloat(longestLineLength(rows: rows)) * characterWidth(family: family)
        let chrome = paneCount > 1 ? paneChromeWidth : singlePaneChromeWidth
        let gutter = paneCount > 1 ? lineNumberGutterWidth(rows: rows, family: family) * 2 + dividerWidth : 0
        let measured = (chrome + textWidth) * panes + gutter
        return max(minimumWidth, viewportWidth, measured)
    }
}
