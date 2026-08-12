#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

namespace lithe::windows::algorithms {

enum class GutterHitZone {
    Annotation,
    LineNumber,
};

struct GutterHit {
    std::uint64_t line = 0;
    GutterHitZone zone = GutterHitZone::LineNumber;
};

std::optional<GutterHit> hitTestGutter(
    double x,
    double y,
    double scrollOffset,
    double gutterWidth,
    std::size_t lineCount,
    double contentTop = 8.0,
    double lineHeight = 20.0,
    double lineNumberWidth = 50.0);

} // namespace lithe::windows::algorithms
