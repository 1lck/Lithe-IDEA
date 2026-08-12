#include "fuzzy_match.h"

#include <cctype>
#include <cstddef>

namespace lithe::windows::algorithms {
namespace {

std::size_t utf8Length(std::string_view value, std::size_t index) {
    const auto first = static_cast<unsigned char>(value[index]);
    std::size_t length = 1;
    if (first >= 0xc2 && first <= 0xdf) length = 2;
    else if (first >= 0xe0 && first <= 0xef) length = 3;
    else if (first >= 0xf0 && first <= 0xf4) length = 4;
    return index + length <= value.size() ? length : 1;
}

bool equalCodePoint(std::string_view left, std::string_view right) {
    if (left.size() != right.size()) return false;
    if (left.size() != 1) return left == right;
    return std::tolower(static_cast<unsigned char>(left.front())) ==
        std::tolower(static_cast<unsigned char>(right.front()));
}

} // namespace

bool fuzzySubsequenceMatch(std::string_view candidate, std::string_view query) {
    if (query.empty()) return true;
    std::size_t candidateIndex = 0;
    std::size_t queryIndex = 0;
    while (candidateIndex < candidate.size() && queryIndex < query.size()) {
        const auto candidateLength = utf8Length(candidate, candidateIndex);
        const auto queryLength = utf8Length(query, queryIndex);
        if (equalCodePoint(candidate.substr(candidateIndex, candidateLength),
                           query.substr(queryIndex, queryLength))) {
            queryIndex += queryLength;
        }
        candidateIndex += candidateLength;
    }
    return queryIndex == query.size();
}

} // namespace lithe::windows::algorithms
