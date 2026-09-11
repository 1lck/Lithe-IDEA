// Adapted from IntelliJ DefaultColorGenerator, Copyright 2000-2024
// JetBrains s.r.o. and contributors. Apache-2.0. See Resources/GitGraph/NOTICE.txt.
import AppKit

enum GitGraphColor {
    /// IDEA generates hues from a signed 32-bit color ID, rather than reducing
    /// the ID modulo a small palette (which merges unrelated adjacent branches).
    static func color(for colorID: Int) -> NSColor {
        guard colorID != 0 else { return .labelColor }
        let id = Int32(truncatingIfNeeded: colorID)
        func component(_ multiplier: Int32, _ offset: Int32) -> CGFloat {
            CGFloat(abs(((id &* multiplier) &+ offset) % 100) + 70) / 255
        }
        let source = NSColor(deviceRed: component(200, 30), green: component(130, 50),
                             blue: component(90, 100), alpha: 1)
        var hue: CGFloat = 0
        source.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
        return NSColor(deviceHue: hue, saturation: 0.4, brightness: 0.65, alpha: 1)
    }
}
