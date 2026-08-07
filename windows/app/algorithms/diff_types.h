#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::algorithms {

enum class DiffRowKind {
    Context,
    Changed,
    Addition,
    Removal,
    Information,
};

struct DiffRow {
    std::optional<std::size_t> oldLine;
    std::optional<std::size_t> newLine;
    std::optional<std::string> left;
    std::optional<std::string> right;
    DiffRowKind kind = DiffRowKind::Context;
    // This is the JSON contract spelling.  Do not use hunkID here: the Rust
    // payload is `hunkId`, and the Swift decoder's capitalization typo was the
    // reason chunk staging silently stopped matching hunks.
    std::string hunkId;
    std::size_t sequence = 0;

    bool hasLeft() const noexcept { return left.has_value(); }
    bool hasRight() const noexcept {
        if (kind == DiffRowKind::Context || kind == DiffRowKind::Information) {
            return right.has_value() || left.has_value();
        }
        return right.has_value();
    }
};

} // namespace lithe::windows::algorithms
