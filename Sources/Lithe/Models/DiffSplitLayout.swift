import CoreGraphics

/// Lays the old and new sides out as independent vertical streams.
///
/// A positional side-by-side diff gives a one-sided addition an empty row on
/// the left for every real row on the right. IntelliJ keeps both editors dense
/// instead: the side without content does not advance, and the center gutter
/// visualizes the resulting offset. This plan is the shared geometry behind
/// that behavior.
struct DiffSplitLayout {
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
        standardRowHeight: CGFloat = 24,
        informationRowHeight: CGFloat = 27
    ) -> DiffSplitLayout {
        struct RunSignature: Equatable {
            let kind: DiffRowKind
            let hasLeft: Bool
            let hasRight: Bool
        }

        struct TransitionRun {
            let id: String
            let signature: RunSignature
            let leftStart: CGFloat
            let rightStart: CGFloat
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
            transitions.append(
                Transition(
                    id: run.id,
                    kind: run.signature.kind,
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
                let signature = RunSignature(kind: kind, hasLeft: hasLeft, hasRight: hasRight)

                if kind.isSplitDifference, hasLeft || hasRight {
                    if activeRun?.signature != signature {
                        finishTransitionRun()
                        activeRun = TransitionRun(
                            id: "transition-\(displayRow.id)",
                            signature: signature,
                            leftStart: leftHeight,
                            rightStart: rightHeight
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
