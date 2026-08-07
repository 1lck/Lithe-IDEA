#include "diff_tokenizer.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <unordered_set>

namespace lithe::windows::algorithms {
namespace {

const std::unordered_set<std::string> keywords{
    "class", "struct", "enum", "protocol", "extension", "func", "let", "var", "if", "else",
    "guard", "switch", "case", "for", "while", "return", "throw", "throws", "try", "catch",
    "async", "await", "public", "private", "internal", "protected", "static", "final", "new",
    "import", "package", "interface", "implements", "extends", "void", "boolean", "int", "long",
    "const", "function", "def", "in", "from", "as", "true", "false", "null", "nil", "self", "this",
};

std::string lower(std::string_view value) {
    std::string result(value);
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return result;
}

bool isIdentifierStart(unsigned char character) {
    return std::isalpha(character) != 0 || character == '_' || character == '@';
}

bool isIdentifierPart(unsigned char character) {
    return std::isalnum(character) != 0 || character == '_';
}

bool isMarkupExtension(std::string_view extension) {
    const auto value = lower(extension);
    return value == "xml" || value == "html" || value == "xhtml" || value == "plist";
}

} // namespace

std::vector<DiffToken> tokenizeDiffText(std::string_view text,
                                        std::string_view fileExtension) {
    if (isMarkupExtension(fileExtension)) {
        std::vector<DiffToken> result;
        std::size_t index = 0;
        while (index < text.size()) {
            const auto start = index;
            if (text[index] == '<') {
                while (index < text.size() && text[index] != '>') ++index;
                if (index < text.size()) ++index;
                result.push_back({std::string(text.substr(start, index - start)), DiffTokenKind::Tag});
            } else {
                while (index < text.size() && text[index] != '<') ++index;
                result.push_back({std::string(text.substr(start, index - start)), DiffTokenKind::Base});
            }
        }
        return result;
    }

    const auto extension = lower(fileExtension);
    if ((extension == "md" || extension == "markdown")) {
        const auto first = text.find_first_not_of(" \t\r\n");
        if (first != std::string_view::npos && text[first] == '#') {
            return {{std::string(text), DiffTokenKind::Comment}};
        }
    }

    std::vector<DiffToken> result;
    std::size_t index = 0;
    while (index < text.size()) {
        const auto start = index;
        const auto character = static_cast<unsigned char>(text[index]);

        if (text[index] == '/' && index + 1 < text.size() && text[index + 1] == '/') {
            result.push_back({std::string(text.substr(index)), DiffTokenKind::Comment});
            break;
        }

        if (text[index] == '"' || text[index] == '\'') {
            const auto quote = text[index++];
            bool escaped = false;
            while (index < text.size()) {
                const auto current = text[index++];
                if (current == quote && !escaped) break;
                escaped = current == '\\' && !escaped;
                if (current != '\\') escaped = false;
            }
            result.push_back({std::string(text.substr(start, index - start)), DiffTokenKind::String});
            continue;
        }

        if (std::isdigit(character) != 0) {
            ++index;
            while (index < text.size() &&
                   (std::isdigit(static_cast<unsigned char>(text[index])) != 0 || text[index] == '.')) {
                ++index;
            }
            result.push_back({std::string(text.substr(start, index - start)), DiffTokenKind::Number});
            continue;
        }

        if (isIdentifierStart(character)) {
            ++index;
            while (index < text.size() && isIdentifierPart(static_cast<unsigned char>(text[index]))) ++index;
            const auto word = text.substr(start, index - start);
            const auto wordString = std::string(word);
            const auto kind = wordString.front() == '@'
                ? DiffTokenKind::Tag
                : keywords.contains(wordString)
                    ? DiffTokenKind::Keyword
                    : (std::isupper(static_cast<unsigned char>(wordString.front())) != 0
                        ? DiffTokenKind::Type : DiffTokenKind::Base);
            result.push_back({wordString, kind});
            continue;
        }

        ++index;
        while (index < text.size()) {
            const auto next = static_cast<unsigned char>(text[index]);
            if (isIdentifierStart(next) || std::isdigit(next) != 0 ||
                text[index] == '"' || text[index] == '\'') break;
            if (text[index] == '/' && index + 1 < text.size() && text[index + 1] == '/') break;
            ++index;
        }
        result.push_back({std::string(text.substr(start, index - start)), DiffTokenKind::Base});
    }
    return result;
}

} // namespace lithe::windows::algorithms
