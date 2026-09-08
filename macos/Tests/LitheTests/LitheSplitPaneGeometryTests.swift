import CoreGraphics
import Testing
@testable import Lithe

/// Pane sizing is where a split refactor silently inverts a divider: the four
/// converted sites disagree on which side is tracked, so the sign flip and the
/// clamping are pinned here rather than left to a view test.
@Suite("Split pane geometry")
struct LitheSplitPaneGeometryTests {
    @Test
    func aLeadingPaneGrowsWithPositiveTranslation() {
        let size = LitheSplitPaneGeometry.resolve(
            start: 200,
            translation: 40,
            placement: .leading,
            minimum: 100,
            maximum: 400
        )
        #expect(size == 240)
    }

    @Test
    func aTrailingPaneShrinksWithPositiveTranslation() {
        // Dragging the divider to the right makes a right-hand pane narrower.
        let size = LitheSplitPaneGeometry.resolve(
            start: 200,
            translation: 40,
            placement: .trailing,
            minimum: 100,
            maximum: 400
        )
        #expect(size == 160)
    }

    @Test
    func draggingPastAnEdgeClampsRatherThanOvershooting() {
        let tooSmall = LitheSplitPaneGeometry.resolve(
            start: 120,
            translation: -500,
            placement: .leading,
            minimum: 100,
            maximum: 400
        )
        let tooLarge = LitheSplitPaneGeometry.resolve(
            start: 380,
            translation: 500,
            placement: .leading,
            minimum: 100,
            maximum: 400
        )

        #expect(tooSmall == 100)
        #expect(tooLarge == 400)
    }

    @Test
    func minimumWinsWhenLiveGeometryPushesMaximumBelowIt() {
        // Hosts derive `maximum` from the container size, so shrinking a window
        // far enough can invert the range. The pane must not collapse past its
        // minimum or the layout flips inside out.
        let size = LitheSplitPaneGeometry.clamp(300, minimum: 220, maximum: 80)
        #expect(size == 220)
    }

    @Test
    func aSizeInsideTheRangeIsLeftAlone() {
        #expect(LitheSplitPaneGeometry.clamp(250, minimum: 100, maximum: 400) == 250)
    }
}
