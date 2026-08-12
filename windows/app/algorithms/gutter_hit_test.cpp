#include "gutter_hit_test.h"

#include <algorithm>
#include <cmath>

namespace lithe::windows::algorithms {

std::optional<GutterHit> hitTestGutter(
    double x,
    double y,
    double scrollOffset,
    double gutterWidth,
    std::size_t lineCount,
    double contentTop,
    double lineHeight,
    double lineNumberWidth) {
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(scrollOffset) ||
        !std::isfinite(gutterWidth) || !std::isfinite(contentTop) ||
        !std::isfinite(lineHeight) || !std::isfinite(lineNumberWidth) ||
        x < 0.0 || y < 0.0 || gutterWidth <= 0.0 || x >= gutterWidth ||
        lineCount == 0 || lineHeight <= 0.0 || lineNumberWidth <= 0.0) {
        return std::nullopt;
    }
    const auto contentY = y + std::max(0.0, scrollOffset) - contentTop;
    if (contentY < 0.0) return std::nullopt;
    const auto line = static_cast<std::size_t>(std::floor(contentY / lineHeight));
    if (line >= lineCount) return std::nullopt;
    const auto lineNumberStart = std::max(0.0, gutterWidth - lineNumberWidth);
    return GutterHit{
        static_cast<std::uint64_t>(line),
        x >= lineNumberStart ? GutterHitZone::LineNumber : GutterHitZone::Annotation,
    };
}

} // namespace lithe::windows::algorithms
