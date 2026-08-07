#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace lithe::windows::algorithms {

class DiffPairing final {
public:
    static constexpr std::size_t MaximumAlignmentCells = 4096;
    static constexpr double MinimumPairSimilarity = 0.5;

    static double similarity(std::string_view left, std::string_view right);
    static std::vector<std::pair<std::optional<std::size_t>,
                                 std::optional<std::size_t>>>
    pairs(const std::vector<std::string>& removed,
          const std::vector<std::string>& added);
};

} // namespace lithe::windows::algorithms
