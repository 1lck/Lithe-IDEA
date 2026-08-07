#include "diff_split_layout.h"

#include <algorithm>
#include <optional>

namespace lithe::windows::algorithms {
namespace {

bool isSplitDifference(DiffRowKind kind) {
    return kind == DiffRowKind::Changed || kind == DiffRowKind::Addition ||
        kind == DiffRowKind::Removal;
}

struct RunSignature {
    DiffRowKind kind;
    bool hasLeft;
    bool hasRight;

    bool operator==(const RunSignature&) const = default;
};

struct TransitionRun {
    std::string id;
    RunSignature signature;
    double leftStart = 0;
    double rightStart = 0;
};

} // namespace

DiffSplitLayout planDiffSplitLayout(const std::vector<DiffDisplayRow>& displayRows,
                                    const std::vector<DiffRowKind>& kinds,
                                    double standardRowHeight,
                                    double informationRowHeight) {
    DiffSplitLayout result;
    std::optional<TransitionRun> activeRun;
    auto rowHeight = [&](const DiffDisplayRow& row, DiffRowKind kind) {
        return row.isCollapsed() || kind == DiffRowKind::Information
            ? informationRowHeight
            : standardRowHeight;
    };
    auto finishTransitionRun = [&] {
        if (!activeRun) return;
        result.transitions.push_back(DiffTransition{
            activeRun->id,
            activeRun->signature.kind,
            {activeRun->leftStart, result.leftHeight},
            {activeRun->rightStart, result.rightHeight},
        });
        activeRun.reset();
    };

    for (std::size_t displayIndex = 0; displayIndex < displayRows.size(); ++displayIndex) {
        const auto& displayRow = displayRows[displayIndex];
        const auto kind = displayIndex < kinds.size()
            ? kinds[displayIndex]
            : displayRow.layoutRow().kind;
        const auto height = rowHeight(displayRow, kind);
        if (displayRow.isCollapsed()) {
            finishTransitionRun();
            result.leftItems.push_back({displayRow, DiffRowKind::Information,
                                        result.leftHeight, height, false});
            result.rightItems.push_back({displayRow, DiffRowKind::Information,
                                         result.rightHeight, height, false});
            result.leftHeight += height;
            result.rightHeight += height;
            continue;
        }

        const auto& row = displayRow.row();
        const auto hasLeft = row.hasLeft();
        const auto hasRight = row.hasRight();
        const RunSignature signature{kind, hasLeft, hasRight};
        if (isSplitDifference(kind) && (hasLeft || hasRight)) {
            if (!activeRun || !(activeRun->signature == signature)) {
                finishTransitionRun();
                activeRun = TransitionRun{
                    "transition-" + displayRow.id(), signature,
                    result.leftHeight, result.rightHeight};
            }
        } else {
            finishTransitionRun();
        }

        if (hasLeft) {
            result.leftItems.push_back({displayRow, kind, result.leftHeight, height, true});
            result.leftHeight += height;
        }
        if (hasRight) {
            result.rightItems.push_back({displayRow, kind, result.rightHeight, height,
                                         !hasLeft});
            result.rightHeight += height;
        }
    }
    finishTransitionRun();
    return result;
}

} // namespace lithe::windows::algorithms
