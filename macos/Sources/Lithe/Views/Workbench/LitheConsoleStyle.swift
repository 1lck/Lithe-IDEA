// Portions adapted from IntelliJ Community, Copyright 2000-2024 JetBrains s.r.o. and contributors.
// SPDX-License-Identifier: Apache-2.0
import AppKit

/// IDEA Community c7f91397: ConsoleViewUtil, inherited Islands editor schemes.
/// Shared by Run and Debug; other output panes retain their existing presentation.
@MainActor
enum LitheConsoleStyle {
    static let defaultFontSize: CGFloat = 13
    // FontPreferences.DEFAULT_LINE_SPACING + EditorView.getLineHeight (default registry path).
    static let lineSpacing: CGFloat = 1.2
    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil((ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)) * lineSpacing)
    }
    static func paragraphStyle(fontSize: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight(for: LitheTheme.editorFont(size: fontSize))
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }
    static func color(_ value: Int) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func foreground(dark: Bool) -> NSColor { color(dark ? 0xBCBEC4 : 0x000000) }
    static func hyperlink(dark: Bool) -> NSColor { color(dark ? 0x548AF7 : 0x006DCC) }
    static func palette(dark: Bool) -> [NSColor] {
        (dark ? [0x000000, 0xF0524F, 0x5C962C, 0xA68A0D, 0x3993D4, 0xA771BF, 0x00A3A3, 0x808080, 0x595959, 0xFF4050, 0x4FC414, 0xE5BF00, 0x1FB0FF, 0xED7EED, 0x00E5E5, 0xFFFFFF] : [0x000000, 0xCE0505, 0x067D17, 0xB28C00, 0x063FDB, 0xB309B3, 0x028E8E, 0x929292, 0x656565, 0xFF1616, 0x16B42C, 0xECC32C, 0x2D61F0, 0xE617E6, 0x15C1C1, 0xC9C9C9]).map(color)
    }
}

