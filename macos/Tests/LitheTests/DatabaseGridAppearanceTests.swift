import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct DatabaseGridAppearanceTests {
    @Test func databaseCanvasTracksTheSharedWorkbenchPalette() throws {
        let previousTheme = AppThemeRuntime.shared.activeTheme
        defer { AppThemeRuntime.shared.activate(previousTheme) }
        // Structural database backgrounds must not introduce their own theme/appearance override.
        for theme in AppColorTheme.allCases {
            AppThemeRuntime.shared.activate(theme)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: name))
                var canvas: NSColor?
                var editor: NSColor?
                var sidebar: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    canvas = NSColor(LitheTheme.DatabaseGrid.background).usingColorSpace(.deviceRGB)
                    editor = NSColor(LitheTheme.editor).usingColorSpace(.deviceRGB)
                    sidebar = NSColor(LitheTheme.sidebar).usingColorSpace(.deviceRGB)
                }
                #expect(try #require(canvas) == #require(editor))
                #expect(try #require(canvas) == #require(sidebar))
            }
        }
    }

    @Test func duplicateQueryColumnNamesKeepFiniteWidths() {
        let widths = LitheTheme.DatabaseGrid.columnWidths(["x", "x", "name"], availableWidth: 600, rowHeaderWidth: 24) { _ in ["2"] }
        #expect(widths.count == 2)
        #expect(widths.values.allSatisfy { $0.isFinite && $0 >= 40 })
        #expect(abs((widths["x"] ?? 0) * 2 + (widths["name"] ?? 0) - 576) < 1)
    }

    @Test func databaseMenuInitiallySelectsOnlyTheExplicitCurrentDatabase() throws {
        var invoked = ""
        let other = LitheContextMenuItem.action("other") { invoked = "other" }
        let current = LitheContextMenuItem.action("current", initiallySelected: true) { invoked = "current" }
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        presenter.show(items: [other, current], at: NSPoint(x: 100, y: 100), appearance: NSAppearance(named: .aqua), locale: Locale(identifier: "en"))
        let panel = try #require(NSApplication.shared.windows.first { $0.delegate === presenter })
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        panel.sendEvent(enter)
        #expect(invoked == "current")
    }

    @Test func mutationHighlightResolvesTheCurrentAppearanceAndPreservesAlpha() throws {
        let source = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(deviceRed: 248.0 / 255, green: 1.0 / 255, blue: 239.0 / 255, alpha: 0.5)
                : NSColor(deviceRed: 8.0 / 255, green: 32.0 / 255, blue: 248.0 / 255, alpha: 0.5)
        })
        // Resolve the same dynamic highlight in both appearances; do not capture the first one.
        let highlighted = LitheTheme.DatabaseGrid.mutationBackground(source, highlighted: true)
        let normal = LitheTheme.DatabaseGrid.mutationBackground(source, highlighted: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var highlight: NSColor?
            var original: NSColor?
            var unchanged: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                highlight = NSColor(highlighted).usingColorSpace(.deviceRGB)
                original = NSColor(source).usingColorSpace(.deviceRGB)
                unchanged = NSColor(normal).usingColorSpace(.deviceRGB)
            }
            let rgb = try #require(highlight)
            #expect(original == unchanged)
            #expect(abs(rgb.alphaComponent - 0.5) < 0.001)
            let expected: [CGFloat] = name == .darkAqua ? [1, 17.0 / 255, 1] : [0, 16.0 / 255, 232.0 / 255]
            for (actual, expected) in zip([rgb.redComponent, rgb.greenComponent, rgb.blueComponent], expected) {
                #expect(abs(actual - expected) < 0.001)
            }
        }
    }
}
