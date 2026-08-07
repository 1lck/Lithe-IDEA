#include "inline_diff.h"

#include <cstdint>
#include <vector>

namespace lithe::windows::algorithms {
namespace {

std::vector<std::uint32_t> scalars(std::string_view value) {
    std::vector<std::uint32_t> result;
    for (std::size_t index = 0; index < value.size();) {
        const auto first = static_cast<unsigned char>(value[index]);
        std::size_t length = 1;
        std::uint32_t scalar = first;
        if (first >= 0xc2 && first <= 0xdf) length = 2;
        else if (first >= 0xe0 && first <= 0xef) length = 3;
        else if (first >= 0xf0 && first <= 0xf4) length = 4;

        bool valid = length > 1 && index + length <= value.size();
        if (valid) {
            scalar = first & ((1u << (8 - length - 1)) - 1u);
            for (std::size_t offset = 1; offset < length; ++offset) {
                const auto byte = static_cast<unsigned char>(value[index + offset]);
                if ((byte & 0xc0) != 0x80) valid = false;
                scalar = (scalar << 6) | (byte & 0x3f);
            }
            if (length == 3) {
                const auto second = static_cast<unsigned char>(value[index + 1]);
                if ((first == 0xe0 && second < 0xa0) ||
                    (first == 0xed && second >= 0xa0)) valid = false;
            }
            if (length == 4) {
                const auto second = static_cast<unsigned char>(value[index + 1]);
                if ((first == 0xf0 && second < 0x90) ||
                    (first == 0xf4 && second >= 0x90)) valid = false;
            }
            if (scalar > 0x10ffff) valid = false;
        }
        if (!valid) {
            length = 1;
            scalar = first >= 0x80 ? 0xfffd : first;
        }
        result.push_back(scalar);
        index += length;
    }
    return result;
}

} // namespace

std::optional<InlineChangedRange> changedRange(
    std::string_view text,
    std::optional<std::string_view> otherText) {
    if (!otherText) return std::nullopt;
    const auto source = scalars(text);
    const auto comparison = scalars(*otherText);
    std::size_t prefix = 0;
    const auto sharedCount = std::min(source.size(), comparison.size());
    while (prefix < sharedCount && source[prefix] == comparison[prefix]) ++prefix;

    std::size_t suffix = 0;
    while (suffix < sharedCount - prefix &&
           source[source.size() - suffix - 1] == comparison[comparison.size() - suffix - 1]) {
        ++suffix;
    }
    const auto end = source.size() - suffix;
    if (prefix >= end) return std::nullopt;
    return InlineChangedRange{prefix, end};
}

} // namespace lithe::windows::algorithms
