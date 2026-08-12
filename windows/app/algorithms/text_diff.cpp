#include "text_diff.h"

#include "diff_pairing.h"

#include <algorithm>
#include <cstddef>
#include <limits>
#include <optional>
#include <utility>

namespace lithe::windows::algorithms {
namespace {

constexpr std::size_t MaximumTraceCells = 2'000'000;
constexpr std::size_t MissingIndex = std::numeric_limits<std::size_t>::max();
constexpr std::string_view HistoryHunkId = "history-snapshot";

enum class EditKind { Equal, Removal, Addition };

struct Edit {
    EditKind kind;
    std::size_t oldIndex = MissingIndex;
    std::size_t newIndex = MissingIndex;
};

std::optional<std::vector<Edit>> myersEdits(const std::vector<std::string>& oldLines,
                                            const std::vector<std::string>& newLines) {
    const auto oldCount = oldLines.size();
    const auto newCount = newLines.size();
    if (oldCount > std::numeric_limits<std::size_t>::max() - newCount) return std::nullopt;
    const auto maximumDistance = oldCount + newCount;
    if (maximumDistance > (std::numeric_limits<std::size_t>::max() - 3) / 2) {
        return std::nullopt;
    }

    const auto width = maximumDistance * 2 + 3;
    if (width > MaximumTraceCells) return std::nullopt;
    const auto offset = maximumDistance + 1;
    std::vector<std::ptrdiff_t> frontier(width, 0);
    frontier[offset + 1] = 0;
    std::vector<std::vector<std::ptrdiff_t>> trace;

    for (std::size_t distance = 0; distance <= maximumDistance; ++distance) {
        if (trace.size() + 1 > MaximumTraceCells / width) return std::nullopt;
        trace.push_back(frontier);
        const auto signedDistance = static_cast<std::ptrdiff_t>(distance);
        for (auto diagonal = -signedDistance; diagonal <= signedDistance; diagonal += 2) {
            const auto position = static_cast<std::size_t>(
                static_cast<std::ptrdiff_t>(offset) + diagonal);
            std::ptrdiff_t x = 0;
            if (diagonal == -signedDistance ||
                (diagonal != signedDistance && frontier[position - 1] < frontier[position + 1])) {
                x = frontier[position + 1];
            } else {
                x = frontier[position - 1] + 1;
            }
            auto y = x - diagonal;
            while (x < static_cast<std::ptrdiff_t>(oldCount) &&
                   y < static_cast<std::ptrdiff_t>(newCount) &&
                   oldLines[static_cast<std::size_t>(x)] ==
                       newLines[static_cast<std::size_t>(y)]) {
                ++x;
                ++y;
            }
            frontier[position] = x;
            if (x < static_cast<std::ptrdiff_t>(oldCount) ||
                y < static_cast<std::ptrdiff_t>(newCount)) continue;

            std::vector<Edit> reversed;
            reversed.reserve(maximumDistance + std::min(oldCount, newCount));
            auto backX = static_cast<std::ptrdiff_t>(oldCount);
            auto backY = static_cast<std::ptrdiff_t>(newCount);
            for (auto backDistance = distance; backDistance > 0; --backDistance) {
                const auto& previous = trace[backDistance];
                const auto diagonalNow = backX - backY;
                const auto backPosition = static_cast<std::size_t>(
                    static_cast<std::ptrdiff_t>(offset) + diagonalNow);
                const auto signedBackDistance = static_cast<std::ptrdiff_t>(backDistance);
                const auto previousDiagonal =
                    diagonalNow == -signedBackDistance ||
                        (diagonalNow != signedBackDistance &&
                         previous[backPosition - 1] < previous[backPosition + 1])
                    ? diagonalNow + 1
                    : diagonalNow - 1;
                const auto previousPosition = static_cast<std::size_t>(
                    static_cast<std::ptrdiff_t>(offset) + previousDiagonal);
                const auto previousX = previous[previousPosition];
                const auto previousY = previousX - previousDiagonal;
                while (backX > previousX && backY > previousY) {
                    --backX;
                    --backY;
                    reversed.push_back({EditKind::Equal,
                                        static_cast<std::size_t>(backX),
                                        static_cast<std::size_t>(backY)});
                }
                if (backX == previousX) {
                    --backY;
                    reversed.push_back({EditKind::Addition, MissingIndex,
                                        static_cast<std::size_t>(backY)});
                } else {
                    --backX;
                    reversed.push_back({EditKind::Removal,
                                        static_cast<std::size_t>(backX), MissingIndex});
                }
            }
            while (backX > 0 && backY > 0) {
                --backX;
                --backY;
                reversed.push_back({EditKind::Equal,
                                    static_cast<std::size_t>(backX),
                                    static_cast<std::size_t>(backY)});
            }
            while (backX > 0) {
                --backX;
                reversed.push_back({EditKind::Removal,
                                    static_cast<std::size_t>(backX), MissingIndex});
            }
            while (backY > 0) {
                --backY;
                reversed.push_back({EditKind::Addition, MissingIndex,
                                    static_cast<std::size_t>(backY)});
            }
            std::reverse(reversed.begin(), reversed.end());
            return reversed;
        }
    }
    return std::nullopt;
}

void appendContext(std::vector<DiffRow>& rows,
                   const std::vector<std::string>& oldLines,
                   const std::vector<std::string>& newLines,
                   std::size_t oldIndex,
                   std::size_t newIndex) {
    rows.push_back({oldIndex + 1, newIndex + 1, oldLines[oldIndex], newLines[newIndex],
                    DiffRowKind::Context, {}, rows.size()});
}

void appendChangedBlock(std::vector<DiffRow>& rows,
                        const std::vector<std::string>& oldLines,
                        const std::vector<std::string>& newLines,
                        const std::vector<std::size_t>& removedIndices,
                        const std::vector<std::size_t>& addedIndices) {
    std::vector<std::string> removed;
    std::vector<std::string> added;
    removed.reserve(removedIndices.size());
    added.reserve(addedIndices.size());
    for (const auto index : removedIndices) removed.push_back(oldLines[index]);
    for (const auto index : addedIndices) added.push_back(newLines[index]);

    for (const auto& [removedOffset, addedOffset] : DiffPairing::pairs(removed, added)) {
        DiffRow row;
        row.kind = removedOffset && addedOffset ? DiffRowKind::Changed
            : removedOffset ? DiffRowKind::Removal : DiffRowKind::Addition;
        if (removedOffset) {
            const auto index = removedIndices[*removedOffset];
            row.oldLine = index + 1;
            row.left = oldLines[index];
        }
        if (addedOffset) {
            const auto index = addedIndices[*addedOffset];
            row.newLine = index + 1;
            row.right = newLines[index];
        }
        row.hunkId = HistoryHunkId;
        row.sequence = rows.size();
        rows.push_back(std::move(row));
    }
}

std::vector<DiffRow> fallbackDiff(const std::vector<std::string>& oldLines,
                                  const std::vector<std::string>& newLines) {
    std::vector<DiffRow> rows;
    const auto sharedCount = std::min(oldLines.size(), newLines.size());
    std::size_t prefix = 0;
    while (prefix < sharedCount && oldLines[prefix] == newLines[prefix]) {
        appendContext(rows, oldLines, newLines, prefix, prefix);
        ++prefix;
    }
    std::size_t suffix = 0;
    while (suffix < sharedCount - prefix &&
           oldLines[oldLines.size() - suffix - 1] == newLines[newLines.size() - suffix - 1]) {
        ++suffix;
    }
    std::vector<std::size_t> removed;
    std::vector<std::size_t> added;
    for (auto index = prefix; index < oldLines.size() - suffix; ++index) removed.push_back(index);
    for (auto index = prefix; index < newLines.size() - suffix; ++index) added.push_back(index);
    appendChangedBlock(rows, oldLines, newLines, removed, added);
    for (std::size_t offset = suffix; offset > 0; --offset) {
        appendContext(rows, oldLines, newLines,
                      oldLines.size() - offset, newLines.size() - offset);
    }
    return rows;
}

} // namespace

std::vector<DiffRow> diffTextLines(const std::vector<std::string>& oldLines,
                                   const std::vector<std::string>& newLines) {
    const auto edits = myersEdits(oldLines, newLines);
    if (!edits) return fallbackDiff(oldLines, newLines);

    std::vector<DiffRow> rows;
    rows.reserve(std::max(oldLines.size(), newLines.size()));
    for (std::size_t editIndex = 0; editIndex < edits->size();) {
        const auto& edit = (*edits)[editIndex];
        if (edit.kind == EditKind::Equal) {
            appendContext(rows, oldLines, newLines, edit.oldIndex, edit.newIndex);
            ++editIndex;
            continue;
        }
        std::vector<std::size_t> removed;
        std::vector<std::size_t> added;
        while (editIndex < edits->size() && (*edits)[editIndex].kind != EditKind::Equal) {
            const auto& changed = (*edits)[editIndex++];
            if (changed.kind == EditKind::Removal) removed.push_back(changed.oldIndex);
            else added.push_back(changed.newIndex);
        }
        appendChangedBlock(rows, oldLines, newLines, removed, added);
    }
    return rows;
}

} // namespace lithe::windows::algorithms
