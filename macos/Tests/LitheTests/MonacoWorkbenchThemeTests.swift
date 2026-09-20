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
        #expect(lithe.dark)
        #expect(!light.dark)
        #expect((codex.bridgePayload["colors"] as? [String: String]) == codex.colors)
    }
}
