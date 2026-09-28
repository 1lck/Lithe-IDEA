import AppKit
import Testing
@testable import Lithe

@Suite("Settings select popup geometry")
struct SettingsSelectPopupGeometryTests {
    @MainActor
    @Test
    func onlyLeftClickOnOriginalControlDefersDismissal() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = window.convertToScreen(NSRect(x: 20, y: 200, width: 190, height: 28))

        func click(at point: NSPoint, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1
            ))
        }

        #expect(LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 100, y: 214)), anchorWindow: window, anchorFrame: anchor
        ))
        #expect(!LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 260, y: 214)), anchorWindow: window, anchorFrame: anchor
        ))
        #expect(!LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 300, y: 50)), anchorWindow: window, anchorFrame: anchor
        ))
        #expect(!LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 100, y: 214), type: .rightMouseDown),
            anchorWindow: window, anchorFrame: anchor
        ))
    }

    @Test
    func opensBelowTheControlWithoutAnArrowGap() {
        let anchor = CGRect(x: 100, y: 500, width: 190, height: 28)
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: anchor,
            size: CGSize(width: 190, height: 90),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(frame == CGRect(x: 100, y: 408, width: 190, height: 90))
    }

    @Test
    func flipsAboveAndClampsToTheVisibleScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: CGRect(x: 950, y: 30, width: 190, height: 28),
            size: CGSize(width: 190, height: 90),
            visibleFrame: visible
        )
        #expect(frame == CGRect(x: 804, y: 60, width: 190, height: 90))
        #expect(visible.contains(frame))
    }

    @Test
    func shrinksToAvailableSpaceWithoutCoveringTheControl() {
        let anchor = CGRect(x: 100, y: 246, width: 190, height: 28)
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: anchor,
            size: CGSize(width: 190, height: 252),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 500)
        )
        #expect(frame == CGRect(x: 100, y: 6, width: 190, height: 238))
        #expect(!frame.intersects(anchor))
    }
}
