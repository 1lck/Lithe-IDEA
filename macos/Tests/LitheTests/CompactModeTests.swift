import Foundation
import Observation
import Testing
@testable import Lithe

@MainActor
struct CompactModeTests {
    @Test
    func preferencePersistsWithoutChangingEditorOrProjectTreeSettings() throws {
        let suite = "lithe-compact-mode-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let runtime = AppThemeRuntime.shared
        let originalTheme = runtime.activeTheme
        let originalCompactMode = runtime.compactMode
        defer {
            defaults.removePersistentDomain(forName: suite)
            runtime.activate(originalTheme)
            runtime.compactMode = originalCompactMode
        }
        let settings = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
        #expect(!settings.compactMode)
        #expect(defaults.object(forKey: "settings.compactMode") == nil)
        settings.editorFontSize = 16
        settings.projectTreeRowHeight = 28
        settings.compactMode = true
        let reloaded = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
        #expect(reloaded.compactMode)
        #expect(reloaded.editorFontSize == 16)
        #expect(reloaded.projectTreeRowHeight == 28)
        reloaded.restoreDefaults()
        #expect(!reloaded.compactMode)
        #expect(!AppSettings(store: MacUserDefaultsStore(defaults: defaults)).compactMode)
    }

    @Test
    func sharedMetricReadsAreObservedAndRegularMetricsReturnWhenDisabled() {
        let runtime = AppThemeRuntime.shared
        let original = runtime.compactMode
        defer { runtime.compactMode = original }
        runtime.compactMode = false
        let observation = DensityObservation()
        let regular = withObservationTracking {
            [LitheTheme.Metrics.toolbarHeight, LitheTheme.Metrics.toolWindowHeaderHeight,
             LitheTheme.Metrics.tabHeight, ActivityBarMetrics.width, ActivityBarMetrics.slotHeight]
        } onChange: {
            MainActor.assumeIsolated { observation.changed = true }
        }
        #expect(regular == [40, 41, 36, 40, 40])
        runtime.compactMode = true
        #expect(observation.changed)
        #expect(LitheTheme.Metrics.toolbarHeight == 32)
        #expect(LitheTheme.Metrics.toolWindowHeaderHeight == 32)
        #expect(LitheTheme.Metrics.tabHeight == 28)
        #expect(LitheTheme.MainToolbar.buttonSize + LitheTheme.MainToolbar.runInsets.top
                + LitheTheme.MainToolbar.runInsets.bottom <= LitheTheme.Metrics.toolbarHeight)
        #expect(ActivityBarMetrics.buttonWidth <= ActivityBarMetrics.width)
        #expect(LitheTheme.Metrics.toolbarIconButtonSize <= LitheTheme.Metrics.toolWindowHeaderHeight)
        runtime.compactMode = false
        #expect(regular == [LitheTheme.Metrics.toolbarHeight, LitheTheme.Metrics.toolWindowHeaderHeight,
                            LitheTheme.Metrics.tabHeight, ActivityBarMetrics.width, ActivityBarMetrics.slotHeight])
    }
}

@MainActor
private final class DensityObservation {
    var changed = false
}
