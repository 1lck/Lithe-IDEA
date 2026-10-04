// Adapted from IntelliJ DefaultColorGenerator, Copyright 2000-2024
// JetBrains s.r.o. and contributors. Apache-2.0. See Resources/GitGraph/NOTICE.txt.
import AppKit
import LitheGitModule

enum GitGraphColor {
    /// VersionControl.Log.Commit.currentBranchBackground in ManyIslands themes,
    /// Community c7f91397daa3a961b4e78bc634fe467a0a7d9ade.
    static func currentBranchBackground(isDark: Bool) -> NSColor {
        isDark ? NSColor(deviceRed: 29 / 255, green: 35 / 255, blue: 54 / 255, alpha: 1)
            : NSColor(deviceRed: 237 / 255, green: 243 / 255, blue: 1, alpha: 1)
    }

    /// ManyIslands{Dark,Light}: VersionControl.GitLog.*IconColor.
    static func reference(_ kind: GitGraphReferenceKind, isDark: Bool) -> NSColor {
        let rgb: Int
        switch kind {
        case .head: rgb = isDark ? 0xF5D273 : 0xFFAF0F
        case .branch: rgb = isDark ? 0x5FAD65 : 0x369650
        case .remote: rgb = isDark ? 0xB589EC : 0x834DF0
        case .tag: rgb = isDark ? 0x868A91 : 0x6C707E
        }
        return NSColor(deviceRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    /// IDEA generates hues from a signed 32-bit color ID, rather than reducing
    /// the ID modulo a small palette (which merges unrelated adjacent branches).
    static func color(for colorID: Int, isDark: Bool) -> NSColor {
        guard colorID != 0 else { return .labelColor }
        let id = Int32(truncatingIfNeeded: colorID)
        func component(_ multiplier: Int32, _ offset: Int32) -> CGFloat {
            CGFloat(abs(((id &* multiplier) &+ offset) % 100) + 70) / 255
        }
        let source = NSColor(deviceRed: component(200, 30), green: component(130, 50),
                             blue: component(90, 100), alpha: 1)
        var hue: CGFloat = 0
        source.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
        // IDEA's light/dark themes override DefaultColorGenerator's fallback.
        return NSColor(deviceHue: hue, saturation: 0.6, brightness: isDark ? 0.6 : 0.7, alpha: 1)
    }

    /// MergeCommitsHighlighter applies to every text column, except selected rows.
    static func commitForeground(parentCount: Int, isSelected: Bool, normal: NSColor, isDark: Bool) -> NSColor {
        parentCount >= 2 && !isSelected ? mergeForeground(isDark: isDark) : normal
    }

    /// IDEA MergeCommitsHighlighter uses the theme's unmatched foreground.
    /// Selected rows retain their normal foreground so they remain readable.
    static func mergeForeground(isDark: Bool) -> NSColor {
        isDark ? NSColor(deviceRed: 111 / 255, green: 115 / 255, blue: 122 / 255, alpha: 1)
            : NSColor(deviceRed: 129 / 255, green: 133 / 255, blue: 148 / 255, alpha: 1)
    }
}
