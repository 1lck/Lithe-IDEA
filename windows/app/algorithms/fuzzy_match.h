#pragma once

#include <string_view>

namespace lithe::windows::algorithms {

// Matches the same ordered-character shape used by Search Everywhere's
// generated `.*c.*h.*a.*r.*` expression. ASCII case is ignored; non-ASCII
// UTF-8 code points are compared without splitting their bytes.
bool fuzzySubsequenceMatch(std::string_view candidate, std::string_view query);

} // namespace lithe::windows::algorithms
