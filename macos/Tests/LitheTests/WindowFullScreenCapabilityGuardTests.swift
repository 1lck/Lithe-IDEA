import AppKit
import Testing
@testable import Lithe

@Suite("Window fullscreen capability guard")
@MainActor
struct WindowFullScreenCapabilityGuardTests {
    @Test
    func guardStripsSwiftUIFullScreenRefusalWhenInstalled() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        window.collectionBehavior.insert(.fullScreenNone)

        window.contentView?.addSubview(WindowFullScreenCapabilityView())

        #expect(!window.collectionBehavior.contains(.fullScreenNone))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test
    func guardRewiresZoomButtonToTheGuardedFullscreenToggle() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        window.collectionBehavior.insert(.fullScreenNone)

        let guardView = WindowFullScreenCapabilityView()
        window.contentView?.addSubview(guardView)

        // AppKit configures the zoom button while the window is created, so a
        // button configured under the refusal would keep maximizing until the
        // guard rewires it.
        let zoomButton = try #require(window.standardWindowButton(.zoomButton))
        #expect(zoomButton.target as? WindowFullScreenCapabilityView === guardView)
        #expect(zoomButton.action == #selector(WindowFullScreenCapabilityView.zoomButtonClicked(_:)))
    }

    @Test
    func guardRestripsTheRefusalWhenSwiftUIReappliesIt() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        window.collectionBehavior.insert(.fullScreenNone)

        window.contentView?.addSubview(WindowFullScreenCapabilityView())
        #expect(!window.collectionBehavior.contains(.fullScreenNone))

        // SwiftUI reapplies the flag during scene updates; the next window
        // update pass must strip it again so the zoom button stays usable.
        window.collectionBehavior.insert(.fullScreenNone)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        #expect(!window.collectionBehavior.contains(.fullScreenNone))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
