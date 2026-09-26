import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct SettingsAppearanceContainerTests {
    @Test
    func changingAppearanceKeepsTheContentIdentity() {
        let recorder = SettingsContentIdentityRecorder()
        let hostingView = NSHostingView(rootView: makeContent(
            themePreference: .light,
            recorder: recorder
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        hostingView.layoutSubtreeIfNeeded()
        let initialSnapshot = recorder.snapshots.last

        hostingView.rootView = makeContent(themePreference: .dark, recorder: recorder)
        hostingView.layoutSubtreeIfNeeded()
        let darkSnapshot = recorder.snapshots.last

        hostingView.rootView = makeContent(themePreference: .system, recorder: recorder)
        hostingView.layoutSubtreeIfNeeded()
        let systemSnapshot = recorder.snapshots.last

        #expect(initialSnapshot != nil)
        #expect(darkSnapshot?.identity == initialSnapshot?.identity)
        #expect(systemSnapshot?.identity == initialSnapshot?.identity)
        #expect(darkSnapshot?.draft == "unsaved draft")
        #expect(systemSnapshot?.draft == "unsaved draft")
    }

    @Test
    func settingsChromeHostKeepsItsSurfaceAndControlsAcrossAppearanceAndReopen() throws {
        let (window, host) = makeWindow(theme: .light)
        defer { window.close() }

        for theme in [AppThemePreference.light, .dark, .system] {
            host.rootView = windowContent(theme: theme)
            try assertWindowChrome(window, host: host, theme: theme)
        }

        window.close()
        #expect(!window.isVisible)
        let (reopened, reopenedHost) = makeWindow(theme: .system)
        defer { reopened.close() }
        try assertWindowChrome(reopened, host: reopenedHost, theme: .system)
        #expect(reopened !== window)
    }

    private func makeWindow(theme: AppThemePreference) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: windowContent(theme: theme))
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    private func windowContent(theme: AppThemePreference) -> AnyView {
        // Clear content makes a missing container background visible in the capture.
        AnyView(SettingsAppearanceContainer(themePreference: theme) {
            Color.clear.frame(width: 400, height: 240)
        })
    }

    private func assertWindowChrome(
        _ window: NSWindow,
        host: NSHostingView<AnyView>,
        theme: AppThemePreference
    ) throws {
        host.layoutSubtreeIfNeeded()
        SettingsWindowChrome.configure(window, title: "Settings", themePreference: theme)
        host.layoutSubtreeIfNeeded()

        #expect(window.appearance?.name == theme.windowAppearance?.name)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.isMovable)
        #expect(try #require(window.standardWindowButton(.closeButton)).isEnabled)
        #expect(try #require(window.standardWindowButton(.miniaturizeButton)).isEnabled == false)
        #expect(try #require(window.standardWindowButton(.zoomButton)).isEnabled)

        let expected = LitheTheme.settingsSurfaceNSColor(for: window.effectiveAppearance)
        #expect(window.backgroundColor.usingColorSpace(.sRGB) == expected.usingColorSpace(.sRGB))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let expectedRGB = try #require(expected.usingColorSpace(.sRGB))
        let samples = try [5, bitmap.pixelsHigh / 2, bitmap.pixelsHigh - 6].map { y in
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y))
            #expect(color.alphaComponent > 0.99, "The settings surface must cover the titlebar and panel")
            return try #require(color.usingColorSpace(.sRGB))
        }
        let panel = samples[1]
        for sample in samples {
            #expect(abs(sample.redComponent - expectedRGB.redComponent) < 0.1)
            #expect(abs(sample.greenComponent - expectedRGB.greenComponent) < 0.1)
            #expect(abs(sample.blueComponent - expectedRGB.blueComponent) < 0.1)
            #expect(abs(sample.redComponent - panel.redComponent) < 0.01)
            #expect(abs(sample.greenComponent - panel.greenComponent) < 0.01)
            #expect(abs(sample.blueComponent - panel.blueComponent) < 0.01)
        }

        var ancestor = window.standardWindowButton(.closeButton)?.superview
        var background: SettingsTitlebarBackgroundView?
        while let view = ancestor, view !== window.contentView {
            background = view.subviews.compactMap { $0 as? SettingsTitlebarBackgroundView }.first
            if background != nil { break }
            ancestor = view.superview
        }
        let titlebarBackground = try #require(background)
        #expect(titlebarBackground.hitTest(NSPoint(x: 200, y: 10)) == nil,
                "The titlebar color layer must not intercept window dragging")
    }

    private func makeContent(
        themePreference: AppThemePreference,
        recorder: SettingsContentIdentityRecorder
    ) -> SettingsAppearanceContainer<SettingsContentIdentityProbe> {
        SettingsAppearanceContainer(themePreference: themePreference) {
            SettingsContentIdentityProbe(recorder: recorder)
        }
    }
}

@MainActor
private final class SettingsContentIdentityRecorder {
    struct Snapshot {
        let identity: ObjectIdentifier
        let draft: String
    }

    var snapshots: [Snapshot] = []
}

@MainActor
private final class SettingsContentState: ObservableObject {
    var draft = ""
}

@MainActor
private struct SettingsContentIdentityProbe: View {
    @StateObject private var state = SettingsContentState()
    let recorder: SettingsContentIdentityRecorder

    var body: some View {
        SettingsContentIdentityReporter(
            state: state,
            recorder: recorder
        )
    }
}

@MainActor
private struct SettingsContentIdentityReporter: NSViewRepresentable {
    let state: SettingsContentState
    let recorder: SettingsContentIdentityRecorder

    func makeNSView(context: Context) -> NSView {
        state.draft = "unsaved draft"
        recordIdentity()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        recordIdentity()
    }

    private func recordIdentity() {
        recorder.snapshots.append(.init(
            identity: ObjectIdentifier(state),
            draft: state.draft
        ))
    }
}
