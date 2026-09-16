import AppKit
import SwiftUI

struct CodeEditorPalette {
    private static let propertyRGB: (red: CGFloat, green: CGFloat, blue: CGFloat) = (79, 148, 250)

    let isDark: Bool
    let theme: AppColorTheme

    static let dark = CodeEditorPalette(isDark: true, theme: .lithe)

    var background: NSColor { themeColor(.editor) }
    var gutterBackground: NSColor { themeColor(.editor) }
    var gutterDivider: NSColor {
        color(
            light: (0.78, 0.79, 0.81, 1),
            dark: (0.204, 0.212, 0.231, 1)
        )
    }
    var text: NSColor {
        guard theme == .lithe else { return themeColor(.primaryText) }
        if !isDark { return themeColor(.primaryText) }
        return color(
            light: (0.122, 0.137, 0.161, 1),
            dark: (0.737, 0.745, 0.769, 1)
        )
    }
    var caret: NSColor { themeColor(.primaryText) }
    var selection: NSColor { themeColor(.accent).withAlphaComponent(isDark ? 0.42 : 0.24) }
    var selectionText: NSColor { themeColor(.primaryText) }
    var currentLine: NSColor { color(light: (0, 0, 0, 0.035), dark: (1, 1, 1, 0.035)) }
    var executionLine: NSColor {
        color(
            light: (0.22, 0.52, 0.91, 0.24),
            dark: (0.18, 0.43, 0.78, 0.72)
        )
    }
    var bracket: NSColor { color(light: (0.18, 0.43, 0.79, 0.19), dark: (0.72, 0.72, 0.72, 0.22)) }
    var symbol: NSColor { color(light: (0.18, 0.43, 0.79, 0.11), dark: (0.68, 0.68, 0.68, 0.14)) }
    var guide: NSColor { themeColor(.guide) }
    var activeGuide: NSColor { themeColor(.activeGuide) }
    var unusedCode: NSColor { color(light: (0.48, 0.49, 0.52, 1), dark: (0.48, 0.48, 0.48, 1)) }
    var link: NSColor { themeColor(.accent) }
    var lineNumber: NSColor { color(light: (0.43, 0.45, 0.49, 1), dark: (0.34, 0.34, 0.34, 1)) }
    var foldHover: NSColor { color(light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.07)) }
    var foldIndicator: NSColor { color(light: (0.28, 0.30, 0.34, 0.58), dark: (0.62, 0.62, 0.62, 0.46)) }
    var foldIndicatorHover: NSColor { color(light: (0.12, 0.14, 0.17, 0.90), dark: (0.86, 0.86, 0.86, 0.96)) }
    var blameText: NSColor { color(light: (0.42, 0.44, 0.48, 1), dark: (0.46, 0.46, 0.46, 1)) }
    var gitAdded: NSColor { color(light: (0.15, 0.62, 0.31, 1), dark: (0.31, 0.78, 0.45, 1)) }
    var gitModified: NSColor { color(light: (0.16, 0.48, 0.86, 1), dark: (0.31, 0.64, 0.96, 1)) }
    var gitDeleted: NSColor { color(light: (0.82, 0.22, 0.25, 1), dark: (0.94, 0.34, 0.37, 1)) }

    var keyword: NSColor { themeColor(.skill) }
    var annotation: NSColor { themeColor(.warning) }
    var type: NSColor { themeColor(.accent) }
    var property: NSColor { color(Self.propertyRGB) }
    var number: NSColor { themeColor(.warning) }
    var string: NSColor { themeColor(.success) }
    var comment: NSColor { themeColor(.secondaryText) }

    private func themeColor(_ token: LitheTheme.ResolvedColorToken) -> NSColor {
        LitheTheme.nsColor(token, theme: theme, isDark: isDark)
    }

    private func color(_ rgb: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> NSColor {
        NSColor(
            srgbRed: rgb.red / 255,
            green: rgb.green / 255,
            blue: rgb.blue / 255,
            alpha: 1
        )
    }

    private func color(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        let components = isDark ? dark : light
        return NSColor(
            srgbRed: components.0,
            green: components.1,
            blue: components.2,
            alpha: components.3
        )
    }
}
