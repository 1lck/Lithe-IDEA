#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

enum class DiffTokenKind {
    Base,
    Keyword,
    Type,
    String,
    Number,
    Comment,
    Tag,
};

struct DiffToken {
    std::string text;
    DiffTokenKind kind = DiffTokenKind::Base;
};

std::vector<DiffToken> tokenizeDiffText(
    std::string_view text,
    std::string_view fileExtension);

} // namespace lithe::windows::algorithms
