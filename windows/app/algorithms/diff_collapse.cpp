#include "diff_collapse.h"

#include <algorithm>

namespace lithe::windows::algorithms {

DiffRow DiffDisplayRow::layoutRow() const {
    if (!isCollapsed()) return row();
    DiffRow result;
    result.kind = DiffRowKind::Information;
    result.sequence = region().startIndex;
    return result;
}

std::string DiffDisplayRow::id() const {
    if (isCollapsed()) return region().id;
    const auto& value = row();
    return "row-" + (value.hunkId.empty() ? "-" : value.hunkId) + "-" +
        (value.oldLine ? std::to_string(*value.oldLine) : "-1") + "-" +
        (value.newLine ? std::to_string(*value.newLine) : "-1") + "-" +
        std::to_string(value.sequence);
}

std::vector<DiffDisplayRow> DiffCollapse::plan(
    const std::vector<DiffRow>& rows,
    const std::unordered_set<std::string>& expandedRegionIDs,
    const std::unordered_set<std::string>& pinnedRowIDs,
    std::size_t threshold,
    std::size_t contextLines) {
    if (rows.empty()) return {};
    std::vector<DiffDisplayRow> display;
    display.reserve(rows.size());
    auto appendRows = [&](std::size_t begin, std::size_t end) {
        for (auto index = begin; index < end; ++index) {
            display.push_back(DiffDisplayRow{rows[index], index});
        }
    };

    std::size_t index = 0;
    while (index < rows.size()) {
        if (rows[index].kind != DiffRowKind::Context) {
            display.push_back(DiffDisplayRow{rows[index], index});
            ++index;
            continue;
        }
        std::size_t runEnd = index;
        while (runEnd < rows.size() && rows[runEnd].kind == DiffRowKind::Context) ++runEnd;

        const auto leadingContext = index == 0
            ? 0
            : std::min(contextLines, runEnd - index);
        const auto trailingContext = runEnd == rows.size()
            ? 0
            : std::min(contextLines, runEnd - index - leadingContext);
        const auto hiddenStart = index + leadingContext;
        const auto hiddenEnd = runEnd >= trailingContext
            ? std::max(hiddenStart, runEnd - trailingContext)
            : hiddenStart;
        const auto hiddenCount = hiddenEnd - hiddenStart;
        const DiffCollapsedRegion region{
            "collapsed-" + std::to_string(hiddenStart) + "-" + std::to_string(hiddenEnd),
            hiddenStart,
            hiddenEnd,
        };
        bool containsPinned = false;
        for (auto pinned = hiddenStart; pinned < hiddenEnd; ++pinned) {
            const DiffDisplayRow candidate{rows[pinned], pinned};
            if (pinnedRowIDs.contains(candidate.id())) {
                containsPinned = true;
                break;
            }
        }
        if (hiddenCount < threshold || expandedRegionIDs.contains(region.id) || containsPinned) {
            appendRows(index, runEnd);
        } else {
            appendRows(index, hiddenStart);
            display.push_back(DiffDisplayRow{region, hiddenStart});
            appendRows(hiddenEnd, runEnd);
        }
        index = runEnd;
    }
    return display;
}

} // namespace lithe::windows::algorithms
