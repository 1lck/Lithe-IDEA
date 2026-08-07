#pragma once

#include <optional>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

std::optional<std::vector<int>> parseVersionComponents(std::string_view version);
bool isNewerVersion(std::string_view candidate, std::string_view current);

} // namespace lithe::windows::algorithms
