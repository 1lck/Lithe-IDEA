import AppKit
import Combine
import SwiftUI
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
    func densityChangesNotifyConsumersAndRegularMetricsReturnWhenDisabled() {
        let runtime = AppThemeRuntime.shared
        let original = runtime.compactMode
        defer { runtime.compactMode = original }
        runtime.compactMode = false
        let observation = DensityObservation()
        let regular = [LitheTheme.Metrics.toolbarHeight, LitheTheme.Metrics.toolWindowHeaderHeight,
                       LitheTheme.Metrics.tabHeight, ActivityBarMetrics.width, ActivityBarMetrics.slotHeight]
        let subscription = runtime.objectWillChange.sink {
            MainActor.assumeIsolated { observation.changes += 1 }
        }
        defer { subscription.cancel() }
        #expect(regular == [40, 41, 36, 40, 40])
        runtime.compactMode = true
        #expect(observation.changes == 1)
        runtime.compactMode = true
        #expect(observation.changes == 1)
        #expect(LitheTheme.Metrics.toolbarHeight == 32)
        #expect(LitheTheme.Metrics.toolWindowHeaderHeight == 32)
        #expect(LitheTheme.Metrics.tabHeight == 28)
        #expect(LitheTheme.MainToolbar.buttonSize + LitheTheme.MainToolbar.runInsets.top
                + LitheTheme.MainToolbar.runInsets.bottom <= LitheTheme.Metrics.toolbarHeight)
        #expect(ActivityBarMetrics.buttonWidth <= ActivityBarMetrics.width)
        #expect(LitheTheme.Metrics.toolbarIconButtonSize <= LitheTheme.Metrics.toolWindowHeaderHeight)
        runtime.compactMode = false
        #expect(observation.changes == 2)
        #expect(regular == [LitheTheme.Metrics.toolbarHeight, LitheTheme.Metrics.toolWindowHeaderHeight,
                            LitheTheme.Metrics.tabHeight, ActivityBarMetrics.width, ActivityBarMetrics.slotHeight])
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func retainedHeaderHostsFollowDensityWithoutReplacingTheirRoots(scheme: ColorScheme) {
        let runtime = AppThemeRuntime.shared
        let original = runtime.compactMode
        defer { runtime.compactMode = original }
        runtime.compactMode = false
        let hosts = ["Terminal", "Commit"].map { title in
            NSHostingView(rootView: LitheToolWindowHeader(title: title)
                .environment(\.colorScheme, scheme))
        }
        for (compact, height) in [(false, CGFloat(41)), (true, CGFloat(32)), (false, CGFloat(41))] {
            runtime.compactMode = compact
            for host in hosts {
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height == height)
            }
        }
    }
}

@MainActor
private final class DensityObservation {
    var changes = 0
}
