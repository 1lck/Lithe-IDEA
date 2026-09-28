import CoreGraphics
import Testing
@testable import Lithe

@Suite("Settings select popup geometry")
struct SettingsSelectPopupGeometryTests {
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
