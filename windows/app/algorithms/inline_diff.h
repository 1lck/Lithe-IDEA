#pragma once

#include <cstddef>
#include <optional>
#include <string_view>

namespace lithe::windows::algorithms {

struct InlineChangedRange {
    // Offsets are Unicode scalar positions, matching Swift's Array(String)
    // indexing used by the macOS diff renderer.  UI adapters can convert them
    // to their native UTF-16 or byte offsets at the boundary.
    std::size_t start = 0;
    std::size_t end = 0;
};

std::optional<InlineChangedRange> changedRange(
    std::string_view text,
    std::optional<std::string_view> otherText);

} // namespace lithe::windows::algorithms
