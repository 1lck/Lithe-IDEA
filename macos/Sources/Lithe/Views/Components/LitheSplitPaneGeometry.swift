import CoreGraphics

/// Pure geometry for split-pane resize calculations.
enum LitheSplitPaneGeometry {
    enum Placement {
        case leading
        case trailing
    }

    static func resolve(
        start: CGFloat,
        translation: CGFloat,
        placement: Placement,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let raw: CGFloat
        switch placement {
        case .leading:
            raw = start + translation
        case .trailing:
            raw = start - translation
        }
        return clamp(raw, minimum: minimum, maximum: maximum)
    }

    static func clamp(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let effectiveMinimum = min(minimum, maximum)
        let effectiveMaximum = max(minimum, maximum)
        return min(max(value, effectiveMinimum), effectiveMaximum)
    }
}
