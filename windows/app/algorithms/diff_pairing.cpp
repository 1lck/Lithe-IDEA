#include "diff_pairing.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <limits>
#include <unordered_map>

namespace lithe::windows::algorithms {
namespace {

std::string trimWhitespace(std::string_view value) {
    std::size_t start = 0;
    std::size_t end = value.size();
    while (start < end && std::isspace(static_cast<unsigned char>(value[start]))) ++start;
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1]))) --end;
    return std::string(value.substr(start, end - start));
}

std::vector<std::string> utf8Characters(std::string_view value) {
    std::vector<std::string> result;
    for (std::size_t index = 0; index < value.size();) {
        const auto first = static_cast<unsigned char>(value[index]);
        std::size_t length = 1;
        if (first >= 0xc2 && first <= 0xdf) length = 2;
        else if (first >= 0xe0 && first <= 0xef) length = 3;
        else if (first >= 0xf0 && first <= 0xf4) length = 4;
        if (index + length > value.size()) length = 1;
        result.emplace_back(value.substr(index, length));
        index += length;
    }
    return result;
}

std::vector<std::string> bigrams(std::string_view value) {
    const auto characters = utf8Characters(value);
    if (characters.size() == 1) return {characters.front() + characters.front()};
    std::vector<std::string> result;
    if (characters.size() >= 2) result.reserve(characters.size() - 1);
    for (std::size_t index = 0; index + 1 < characters.size(); ++index) {
        result.push_back(characters[index] + characters[index + 1]);
    }
    return result;
}

} // namespace

double DiffPairing::similarity(std::string_view left, std::string_view right) {
    const auto leftTrimmed = trimWhitespace(left);
    const auto rightTrimmed = trimWhitespace(right);
    if (leftTrimmed == rightTrimmed) return 1.0;
    if (leftTrimmed.empty() || rightTrimmed.empty()) return 0.0;

    const auto leftBigrams = bigrams(leftTrimmed);
    auto rightBigrams = bigrams(rightTrimmed);
    const auto total = leftBigrams.size() + rightBigrams.size();
    std::size_t shared = 0;
    for (const auto& bigram : leftBigrams) {
        const auto position = std::find(rightBigrams.begin(), rightBigrams.end(), bigram);
        if (position == rightBigrams.end()) continue;
        rightBigrams.erase(position);
        ++shared;
    }
    return total == 0 ? 0.0 : static_cast<double>(2 * shared) / total;
}

std::vector<std::pair<std::optional<std::size_t>, std::optional<std::size_t>>>
DiffPairing::pairs(const std::vector<std::string>& removed,
                   const std::vector<std::string>& added) {
    const auto rows = removed.size();
    const auto columns = added.size();
    if (rows == 1 && columns == 1) return {{0, 0}};
    if (rows == 0 || columns == 0 || rows > MaximumAlignmentCells / std::max<std::size_t>(1, columns)) {
        std::vector<std::pair<std::optional<std::size_t>, std::optional<std::size_t>>> result;
        result.reserve(std::max(rows, columns));
        for (std::size_t index = 0; index < std::max(rows, columns); ++index) {
            result.emplace_back(index < rows ? std::optional<std::size_t>(index) : std::nullopt,
                                index < columns ? std::optional<std::size_t>(index) : std::nullopt);
        }
        return result;
    }

    std::vector<std::vector<double>> score(
        rows + 1, std::vector<double>(columns + 1, 0.0));
    for (std::size_t i = rows; i-- > 0;) {
        for (std::size_t j = columns; j-- > 0;) {
            const auto value = similarity(removed[i], added[j]);
            const auto paired = value >= MinimumPairSimilarity
                ? value + score[i + 1][j + 1]
                : -std::numeric_limits<double>::infinity();
            score[i][j] = std::max({paired, score[i + 1][j], score[i][j + 1]});
        }
    }

    std::vector<std::pair<std::optional<std::size_t>, std::optional<std::size_t>>> result;
    result.reserve(std::max(rows, columns));
    std::size_t i = 0;
    std::size_t j = 0;
    while (i < rows && j < columns) {
        const auto value = similarity(removed[i], added[j]);
        const auto paired = value >= MinimumPairSimilarity
            ? value + score[i + 1][j + 1]
            : -std::numeric_limits<double>::infinity();
        if (paired >= score[i + 1][j] && paired >= score[i][j + 1]) {
            result.emplace_back(i, j);
            ++i;
            ++j;
        } else if (score[i + 1][j] >= score[i][j + 1]) {
            result.emplace_back(i, std::nullopt);
            ++i;
        } else {
            result.emplace_back(std::nullopt, j);
            ++j;
        }
    }
    while (i < rows) result.emplace_back(i++, std::nullopt);
    while (j < columns) result.emplace_back(std::nullopt, j++);
    return result;
}

} // namespace lithe::windows::algorithms
