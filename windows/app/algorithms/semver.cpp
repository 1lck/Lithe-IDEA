#include "semver.h"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <string>

namespace lithe::windows::algorithms {
namespace {

std::string trim(std::string_view value) {
    std::size_t start = 0;
    std::size_t end = value.size();
    while (start < end && std::isspace(static_cast<unsigned char>(value[start]))) ++start;
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1]))) --end;
    return std::string(value.substr(start, end - start));
}

} // namespace

std::optional<std::vector<int>> parseVersionComponents(std::string_view version) {
    auto normalized = trim(version);
    if (!normalized.empty() && normalized.front() == 'v') normalized.erase(0, 1);
    const auto dash = normalized.find('-');
    if (dash != std::string::npos) normalized.erase(dash);

    std::vector<int> result;
    std::size_t start = 0;
    while (start <= normalized.size()) {
        const auto end = normalized.find('.', start);
        const auto partEnd = end == std::string::npos ? normalized.size() : end;
        if (partEnd > start) {
            int value = 0;
            const auto* begin = normalized.data() + start;
            const auto* finish = normalized.data() + partEnd;
            const auto parsed = std::from_chars(begin, finish, value);
            if (parsed.ec != std::errc{} || parsed.ptr != finish) return std::nullopt;
            result.push_back(value);
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    if (result.empty()) return std::nullopt;
    return result;
}

bool isNewerVersion(std::string_view candidate, std::string_view current) {
    const auto candidateComponents = parseVersionComponents(candidate);
    const auto currentComponents = parseVersionComponents(current);
    if (!candidateComponents || !currentComponents) return false;
    const auto count = std::max(candidateComponents->size(), currentComponents->size());
    for (std::size_t index = 0; index < count; ++index) {
        const auto candidateValue = index < candidateComponents->size()
            ? (*candidateComponents)[index] : 0;
        const auto currentValue = index < currentComponents->size()
            ? (*currentComponents)[index] : 0;
        if (candidateValue != currentValue) return candidateValue > currentValue;
    }
    return false;
}

} // namespace lithe::windows::algorithms
