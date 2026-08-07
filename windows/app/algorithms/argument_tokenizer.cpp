#include "argument_tokenizer.h"

#include <cctype>

namespace lithe::windows::algorithms {

std::vector<std::string> tokenizeArguments(std::string_view input) {
    std::vector<std::string> result;
    std::string current;
    char quote = '\0';
    bool escaped = false;

    for (const auto character : input) {
        if (escaped) {
            current.push_back(character);
            escaped = false;
            continue;
        }
        if (character == '\\' && quote != '\'') {
            escaped = true;
            continue;
        }
        if (character == '\'' || character == '"') {
            if (quote == character) quote = '\0';
            else if (quote == '\0') quote = character;
            else current.push_back(character);
            continue;
        }
        if (std::isspace(static_cast<unsigned char>(character)) && quote == '\0') {
            if (!current.empty()) {
                result.push_back(std::move(current));
                current.clear();
            }
        } else {
            current.push_back(character);
        }
    }
    if (escaped) current.push_back('\\');
    if (!current.empty()) result.push_back(std::move(current));
    return result;
}

} // namespace lithe::windows::algorithms
