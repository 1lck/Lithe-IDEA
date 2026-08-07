#include "editor_position.h"

namespace lithe::windows::app {

EditorPosition EditorPosition::fromOneBased(std::uint64_t line,
                                             std::uint64_t column) noexcept {
    return {
        line == 0 ? 0 : line - 1,
        column == 0 ? 0 : column - 1,
    };
}

EditorPosition EditorPosition::fromZeroBased(std::uint64_t line,
                                              std::uint64_t column) noexcept {
    return {line, column};
}

} // namespace lithe::windows::app
