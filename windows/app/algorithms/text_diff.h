#pragma once

#include "diff_types.h"

#include <string>
#include <vector>

namespace lithe::windows::algorithms {

// Produces aligned, side-by-side rows. Equal lines anchor the alignment and
// adjacent removal/addition blocks are paired by similarity where possible.
std::vector<DiffRow> diffTextLines(const std::vector<std::string>& oldLines,
                                   const std::vector<std::string>& newLines);

} // namespace lithe::windows::algorithms
