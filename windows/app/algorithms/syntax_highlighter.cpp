#include "syntax_highlighter.h"

#include <algorithm>
#include <cctype>
#include <string_view>
#include <unordered_set>

namespace lithe::windows::algorithms {
namespace {

const std::unordered_set<std::string_view> keywords{
    "class", "struct", "enum", "protocol", "extension", "func", "let", "var", "if", "else",
    "guard", "switch", "case", "for", "while", "return", "throw", "throws", "try", "catch",
    "async", "await", "public", "private", "internal", "protected", "static", "final", "new",
    "import", "package", "interface", "implements", "extends", "void", "boolean", "int", "long",
    "const", "function", "def", "in", "from", "as", "true", "false", "null", "nil", "self", "this",
};

bool identifierStart(unsigned char value) {
    return std::isalpha(value) != 0 || value == '_';
}

bool identifierPart(unsigned char value) {
    return std::isalnum(value) != 0 || value == '_';
}

void append(std::vector<SyntaxHighlightSpan>& result,
            std::size_t start,
            std::size_t end,
            SyntaxHighlightKind kind) {
    if (start < end) result.push_back({start, end, kind});
}

} // namespace

std::vector<SyntaxHighlightSpan> highlightSyntax(std::string_view text) {
    std::vector<SyntaxHighlightSpan> result;

    // Keyword, annotation, type, and number passes.  They deliberately use
    // ASCII boundaries like the original regular expressions; Java/Swift
    // identifiers are handled by the editor's native text layer later.
    std::size_t index = 0;
    while (index < text.size()) {
        if (text[index] == '@' && index + 1 < text.size() &&
            (std::isalpha(static_cast<unsigned char>(text[index + 1])) != 0 || text[index + 1] == '_')) {
            const auto start = index++;
            while (index < text.size() &&
                   (std::isalnum(static_cast<unsigned char>(text[index])) != 0 || text[index] == '_')) ++index;
            append(result, start, index, SyntaxHighlightKind::Annotation);
            continue;
        }
        if (identifierStart(static_cast<unsigned char>(text[index]))) {
            const auto start = index++;
            while (index < text.size() && identifierPart(static_cast<unsigned char>(text[index]))) ++index;
            const auto word = text.substr(start, index - start);
            if (keywords.contains(word)) append(result, start, index, SyntaxHighlightKind::Keyword);
            else if (!word.empty() && std::isupper(static_cast<unsigned char>(word.front())) != 0) {
                append(result, start, index, SyntaxHighlightKind::Type);
            }
            continue;
        }
        if (std::isdigit(static_cast<unsigned char>(text[index])) != 0) {
            const auto start = index++;
            while (index < text.size() &&
                   (std::isdigit(static_cast<unsigned char>(text[index])) != 0 || text[index] == '.')) ++index;
            append(result, start, index, SyntaxHighlightKind::Number);
            continue;
        }
        ++index;
    }

    // String pass.  It is intentionally independent from the word pass, just
    // like the original regex sequence, so a keyword inside a string is later
    // covered by the string span.
    index = 0;
    while (index < text.size()) {
        if (text[index] != '"' && text[index] != '\'') {
            ++index;
            continue;
        }
        const auto quote = text[index++];
        const auto start = index - 1;
        bool escaped = false;
        while (index < text.size()) {
            const auto current = text[index++];
            if (current == quote && !escaped) break;
            escaped = current == '\\' && !escaped;
            if (current != '\\') escaped = false;
        }
        append(result, start, index, SyntaxHighlightKind::String);
    }

    // Comment pass, including the three forms used by the macOS regex.
    index = 0;
    while (index < text.size()) {
        if ((text[index] == '/' && index + 1 < text.size() && text[index + 1] == '/') ||
            text[index] == '#') {
            const auto start = index;
            while (index < text.size() && text[index] != '\n') ++index;
            append(result, start, index, SyntaxHighlightKind::Comment);
            continue;
        }
        if (text[index] == '/' && index + 1 < text.size() && text[index + 1] == '*') {
            const auto start = index;
            index += 2;
            while (index + 1 < text.size() && !(text[index] == '*' && text[index + 1] == '/')) ++index;
            if (index + 1 < text.size()) index += 2;
            append(result, start, index, SyntaxHighlightKind::Comment);
            continue;
        }
        ++index;
    }
    return result;
}

} // namespace lithe::windows::algorithms
