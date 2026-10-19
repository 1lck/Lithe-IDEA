import AppKit
import Testing
@testable import Lithe

@Suite("Monaco workbench theme")
struct MonacoWorkbenchThemeTests {
    @Test func workbenchBackgroundMakesOnlyTheEditorSurfaceTransparent() {
        let solid = MonacoWorkbenchThemeConfiguration(
            colorTheme: .lithe,
            isDark: false,
            revealsWorkbenchBackground: false
        )
        let wallpaper = MonacoWorkbenchThemeConfiguration(
            colorTheme: .lithe,
            isDark: false,
            revealsWorkbenchBackground: true
        )

        #expect(solid.colors["background"] == "#FFFFFFFF")
        #expect(wallpaper.colors["background"] == "#00000000")
        #expect(wallpaper.colors["foreground"] == solid.colors["foreground"])
        #expect(wallpaper.id != solid.id)
    }

    @Test func appColorThemeAndAppearanceProduceDistinctMonacoThemes() {
        let lithe = MonacoWorkbenchThemeConfiguration(
            colorTheme: .lithe,
            isDark: true,
            revealsWorkbenchBackground: false
        )
        let codex = MonacoWorkbenchThemeConfiguration(
            colorTheme: .codex,
            isDark: true,
            revealsWorkbenchBackground: false
        )
        let linear = MonacoWorkbenchThemeConfiguration(
            colorTheme: .linear,
            isDark: true,
            revealsWorkbenchBackground: false
        )
        let light = MonacoWorkbenchThemeConfiguration(
            colorTheme: .lithe,
            isDark: false,
            revealsWorkbenchBackground: false
        )

        #expect(Set([lithe.id, codex.id, linear.id, light.id]).count == 4)
        #expect(Set([
            lithe.colors["background"],
            codex.colors["background"],
            linear.colors["background"]
        ]).count == 3)
        #expect(lithe.colors["background"] == "#191A1CFF")
        #expect(lithe.colors["guide"] == "#323438FF")
        #expect(lithe.colors["activeGuide"] == "#4E5157FF")
        #expect(lithe.colors["lineNumber"] == "#4B5059FF")
        #expect(lithe.colors["activeLineNumber"] == "#A1A3ABFF")
        #expect(light.colors["activeLineNumber"] == light.colors["foreground"])
        for token: LitheTheme.ResolvedColorToken in [.editor, .sidebar, .toolHeader] {
            let color = LitheTheme.nsColor(token, theme: .lithe, isDark: true).usingColorSpace(.sRGB)!
            #expect(abs(color.redComponent - 25.0 / 255.0) < 0.000001)
            #expect(abs(color.greenComponent - 26.0 / 255.0) < 0.000001)
            #expect(abs(color.blueComponent - 28.0 / 255.0) < 0.000001)
        }
        #expect(lithe.dark)
        #expect(!light.dark)
        #expect((codex.bridgePayload["colors"] as? [String: String]) == codex.colors)
    }
}
