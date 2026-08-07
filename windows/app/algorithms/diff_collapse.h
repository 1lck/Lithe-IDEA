#pragma once

#include "diff_types.h"

#include <cstddef>
#include <string>
#include <unordered_set>
#include <variant>
#include <vector>

namespace lithe::windows::algorithms {

struct DiffCollapsedRegion {
    std::string id;
    std::size_t startIndex = 0;
    std::size_t endIndex = 0;

    std::size_t hiddenRowCount() const noexcept { return endIndex - startIndex; }
};

struct DiffDisplayRow {
    std::variant<DiffRow, DiffCollapsedRegion> value;
    std::size_t sourceIndex = 0;

    bool isCollapsed() const noexcept {
        return std::holds_alternative<DiffCollapsedRegion>(value);
    }
    const DiffRow& row() const { return std::get<DiffRow>(value); }
    const DiffCollapsedRegion& region() const {
        return std::get<DiffCollapsedRegion>(value);
    }
    DiffRow layoutRow() const;
    std::string id() const;
};

class DiffCollapse final {
public:
    static constexpr std::size_t DefaultThreshold = 12;
    static constexpr std::size_t DefaultContextLines = 3;

    static std::vector<DiffDisplayRow> plan(
        const std::vector<DiffRow>& rows,
        const std::unordered_set<std::string>& expandedRegionIDs = {},
        const std::unordered_set<std::string>& pinnedRowIDs = {},
        std::size_t threshold = DefaultThreshold,
        std::size_t contextLines = DefaultContextLines);
};

} // namespace lithe::windows::algorithms
