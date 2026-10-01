import Foundation
import CoreGraphics
import LitheGitModule

/// Lays the old and new sides out as independent vertical streams.
///
/// A positional side-by-side diff gives a one-sided addition an empty row on
/// the left for every real row on the right. IntelliJ keeps both editors dense
/// instead: the side without content does not advance, and the center gutter
/// visualizes the resulting offset. This plan is the shared geometry behind
/// that behavior.
struct DiffSplitLayout {
    struct InlineHighlight {
        let range: Range<Int>
        let kind: DiffRowKind

        static func compare(_ left: String, _ right: String) -> (left: Self?, right: Self?) {
            let old = Array(left), new = Array(right)
            var prefix = 0, suffix = 0
            let sharedCount = min(old.count, new.count)
            while prefix < sharedCount, old[prefix] == new[prefix] { prefix += 1 }
            while suffix < sharedCount - prefix,
                  old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
            let oldEnd = old.count - suffix, newEnd = new.count - suffix
            let kind: DiffRowKind = prefix == oldEnd ? .addition : prefix == newEnd ? .removal : .changed
            return (prefix < oldEnd ? Self(range: prefix..<oldEnd, kind: kind) : nil,
                    prefix < newEnd ? Self(range: prefix..<newEnd, kind: kind) : nil)
        }
    }
    /// Presentation identity: frame changes reuse the same prepared text storage.
    let identity = UUID()
    struct Item: Identifiable {
        let displayRow: DiffDisplayRow
        let kind: DiffRowKind
        let top: CGFloat
        let height: CGFloat
        let isScrollAnchor: Bool
        var inlineHighlight: InlineHighlight? = nil

        var id: String { displayRow.id }
    }

    struct Transition: Identifiable {
        let id: String
        let kind: DiffRowKind
        let leftRange: ClosedRange<CGFloat>
        let rightRange: ClosedRange<CGFloat>

        var isAddition: Bool {
            leftRange.lowerBound == leftRange.upperBound
                && rightRange.lowerBound < rightRange.upperBound
        }

        var isRemoval: Bool {
            rightRange.lowerBound == rightRange.upperBound
                && leftRange.lowerBound < leftRange.upperBound
        }
    }

    let leftItems: [Item]
    let rightItems: [Item]
    let transitions: [Transition]
    let leftHeight: CGFloat
    let rightHeight: CGFloat

    var contentHeight: CGFloat { max(leftHeight, rightHeight) }
    let lineNumberGutterWidth: CGFloat

    static func plan(
        displayRows: [DiffDisplayRow],
        kinds: [DiffRowKind],
        gutterWidth: CGFloat? = nil,
        standardRowHeight: CGFloat = DiffLayoutMetrics.rowHeight,
        informationRowHeight: CGFloat = 27
    ) -> DiffSplitLayout {
        struct TransitionRun {
            let id: String
            let leftStart: CGFloat
            let rightStart: CGFloat
            let leftIndex: Int
            let rightIndex: Int
        }

        var leftItems: [Item] = []
        var rightItems: [Item] = []
        var transitions: [Transition] = []
        var leftHeight: CGFloat = 0
        var rightHeight: CGFloat = 0
        var activeRun: TransitionRun?

        func rowHeight(for displayRow: DiffDisplayRow, kind: DiffRowKind) -> CGFloat {
            if case .collapsed = displayRow { return informationRowHeight }
            return kind == .information ? informationRowHeight : standardRowHeight
        }

        func finishTransitionRun() {
            guard let run = activeRun else { return }
            // IDEA's SimpleDiffChange classifies a line fragment by both source
            // ranges, not the positional row pairs supplied by our Core adapter.
            let kind: DiffRowKind = leftHeight == run.leftStart ? .addition
                : rightHeight == run.rightStart ? .removal : .changed
            func source(_ item: Item, side: DiffSide) -> String {
                let row = item.displayRow.layoutRow
                return side == .left ? row.left ?? "" : row.rightText ?? ""
            }
            // Preserve the existing prefix/suffix highlighter, but compare the
            // complete replacement, never positional row pairs. A reflowed
            // method call is one modification, not alternating insert/delete.
            // ponytail: one inner span per fragment; use provider-owned inner
            // fragments if disjoint word edits need finer highlighting.
            let highlight = InlineHighlight.compare(
                leftItems[run.leftIndex...].map { source($0, side: .left) }.joined(separator: "\n"),
                rightItems[run.rightIndex...].map { source($0, side: .right) }.joined(separator: "\n"))
            func apply(_ items: inout [Item], start: Int, side: DiffSide, highlight: InlineHighlight?) {
                var offset = 0
                for index in start..<items.count {
                    let item = items[index]
                    let length = source(item, side: side).count
                    let lower = max(offset, highlight?.range.lowerBound ?? offset)
                    let upper = min(offset + length, highlight?.range.upperBound ?? offset)
                    items[index] = Item(displayRow: item.displayRow, kind: kind, top: item.top,
                        height: item.height, isScrollAnchor: item.isScrollAnchor,
                        inlineHighlight: kind == .changed && lower < upper
                            ? InlineHighlight(range: (lower - offset)..<(upper - offset), kind: highlight!.kind) : nil)
                    offset += length + 1
                }
            }
            apply(&leftItems, start: run.leftIndex, side: .left, highlight: highlight.left)
            apply(&rightItems, start: run.rightIndex, side: .right, highlight: highlight.right)
            transitions.append(
                Transition(
                    id: run.id,
                    kind: kind,
                    leftRange: run.leftStart...leftHeight,
                    rightRange: run.rightStart...rightHeight
                )
            )
            activeRun = nil
        }

        for (displayIndex, displayRow) in displayRows.enumerated() {
            let kind = displayIndex < kinds.count ? kinds[displayIndex] : displayRow.layoutRow.kind
            let height = rowHeight(for: displayRow, kind: kind)

            switch displayRow {
            case .collapsed:
                finishTransitionRun()
                leftItems.append(
                    Item(
                        displayRow: displayRow,
                        kind: .information,
                        top: leftHeight,
                        height: height,
                        isScrollAnchor: false
                    )
                )
                rightItems.append(
                    Item(
                        displayRow: displayRow,
                        kind: .information,
                        top: rightHeight,
                        height: height,
                        isScrollAnchor: false
                    )
                )
                leftHeight += height
                rightHeight += height

            case let .row(row, _):
                let hasLeft = row.left != nil
                let hasRight = row.rightText != nil
                if kind.isSplitDifference, hasLeft || hasRight {
                    if activeRun == nil {
                        activeRun = TransitionRun(
                            id: "transition-\(displayRow.id)",
                            leftStart: leftHeight,
                            rightStart: rightHeight,
                            leftIndex: leftItems.count,
                            rightIndex: rightItems.count
                        )
                    }
                } else {
                    finishTransitionRun()
                }

                if hasLeft {
                    leftItems.append(
                        Item(
                            displayRow: displayRow,
                            kind: kind,
                            top: leftHeight,
                            height: height,
                            isScrollAnchor: true
                        )
                    )
                    leftHeight += height
                }

                if hasRight {
                    rightItems.append(
                        Item(
                            displayRow: displayRow,
                            kind: kind,
                            top: rightHeight,
                            height: height,
                            isScrollAnchor: !hasLeft
                        )
                    )
                    rightHeight += height
                }
            }
        }

        finishTransitionRun()
        return DiffSplitLayout(
            leftItems: leftItems,
            rightItems: rightItems,
            transitions: transitions,
            leftHeight: leftHeight,
            rightHeight: rightHeight,
            lineNumberGutterWidth: gutterWidth ?? DiffLayoutMetrics.lineNumberGutterWidth(maximumLine:
                displayRows.reduce(1) { max($0, $1.layoutRow.oldLine ?? 0, $1.layoutRow.newLine ?? 0) })
        )
    }
}

extension DiffRowKind {
    var isSplitDifference: Bool {
        switch self {
        case .changed, .addition, .removal: true
        case .context, .information: false
        }
    }
}
