#pragma once

#include "diff_collapse.h"

#include <cstddef>
#include <utility>
#include <vector>

namespace lithe::windows::algorithms {

struct DiffLayoutItem {
    DiffDisplayRow displayRow;
    DiffRowKind kind = DiffRowKind::Context;
    double top = 0;
    double height = 0;
    bool isScrollAnchor = false;
};

struct DiffTransition {
    std::string id;
    DiffRowKind kind = DiffRowKind::Changed;
    std::pair<double, double> leftRange{0, 0};
    std::pair<double, double> rightRange{0, 0};

    bool isAddition() const noexcept {
        return leftRange.first == leftRange.second &&
            rightRange.first < rightRange.second;
    }
    bool isRemoval() const noexcept {
        return rightRange.first == rightRange.second &&
            leftRange.first < leftRange.second;
    }
};

struct DiffSplitLayout {
    std::vector<DiffLayoutItem> leftItems;
    std::vector<DiffLayoutItem> rightItems;
    std::vector<DiffTransition> transitions;
    double leftHeight = 0;
    double rightHeight = 0;

    double contentHeight() const noexcept {
        return leftHeight > rightHeight ? leftHeight : rightHeight;
    }
};

DiffSplitLayout planDiffSplitLayout(
    const std::vector<DiffDisplayRow>& displayRows,
    const std::vector<DiffRowKind>& kinds,
    double standardRowHeight = 24,
    double informationRowHeight = 27);

} // namespace lithe::windows::algorithms
