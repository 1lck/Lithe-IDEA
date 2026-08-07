#pragma once

#include <cstdint>

namespace lithe::windows::app {

// Internal editor coordinates are always zero-based and use UTF-16 columns,
// matching Qt QString and the LSP/JDT LS protocol.
struct EditorPosition {
    std::uint64_t line = 0;
    std::uint64_t utf16Column = 0;

    static EditorPosition fromOneBased(std::uint64_t line, std::uint64_t column) noexcept;
    static EditorPosition fromZeroBased(std::uint64_t line, std::uint64_t column) noexcept;

    std::uint64_t displayLine() const noexcept { return line + 1; }
    std::uint64_t displayColumn() const noexcept { return utf16Column + 1; }
};

} // namespace lithe::windows::app
