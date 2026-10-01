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
    /// Presentation identity: frame changes reuse the same prepared text storage.
    let identity = UUID()
    struct Item: Identifiable {
        let displayRow: DiffDisplayRow
        let kind: DiffRowKind
        let top: CGFloat
        let height: CGFloat
        let isScrollAnchor: Bool

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

    static func plan(
        displayRows: [DiffDisplayRow],
        kinds: [DiffRowKind],
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
            for index in run.leftIndex..<leftItems.count {
                let item = leftItems[index]
                leftItems[index] = Item(displayRow: item.displayRow, kind: kind, top: item.top,
                    height: item.height, isScrollAnchor: item.isScrollAnchor)
            }
            for index in run.rightIndex..<rightItems.count {
                let item = rightItems[index]
                rightItems[index] = Item(displayRow: item.displayRow, kind: kind, top: item.top,
                    height: item.height, isScrollAnchor: item.isScrollAnchor)
            }
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
            rightHeight: rightHeight
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
