#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

std::vector<std::string> tokenizeArguments(std::string_view input);

} // namespace lithe::windows::algorithms
