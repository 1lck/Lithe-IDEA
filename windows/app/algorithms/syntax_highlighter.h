#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

enum class SyntaxHighlightKind {
    Keyword,
    Annotation,
    Type,
    Number,
    String,
    Comment,
};

struct SyntaxHighlightSpan {
    std::size_t start = 0;
    std::size_t end = 0;
    SyntaxHighlightKind kind = SyntaxHighlightKind::Keyword;
};

// Returns byte ranges in application order, matching the six regex passes in
// the macOS editor.  Later spans intentionally may overlap earlier ones;
// callers apply them in order so comments/strings can override keywords.
std::vector<SyntaxHighlightSpan> highlightSyntax(std::string_view text);

} // namespace lithe::windows::algorithms
