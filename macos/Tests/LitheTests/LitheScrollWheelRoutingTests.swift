import AppKit
import Testing
@testable import Lithe

@MainActor
struct LitheScrollWheelRoutingTests {
    @Test
    func scrollableNestedEditorKeepsTheScrollEvent() {
        let hierarchy = makeScrollHierarchy(nestedOriginY: 100, outerScrollY: 100)
        hierarchy.nested.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let hitView = hierarchy.outer.hitTest(NSPoint(x: 30, y: 30))
        #expect(hitView === hierarchy.textView)

        #expect(
            LitheScrollWheelRouting.destination(
                hitView: hitView,
                within: hierarchy.outer,
                deltaX: 0,
                deltaY: -10
            ) == .nested
        )
    }

    @Test
    func outerSettingsPageTakesOverAtTheNestedEditorsBoundary() {
        let hierarchy = makeScrollHierarchy(nestedOriginY: 100, outerScrollY: 100)
        hierarchy.nested.contentView.scroll(to: NSPoint(x: 0, y: 300))
        let hitView = hierarchy.outer.hitTest(NSPoint(x: 30, y: 30))
        #expect(hitView === hierarchy.textView)

        #expect(
            LitheScrollWheelRouting.destination(
                hitView: hitView,
                within: hierarchy.outer,
                deltaX: 0,
                deltaY: -10
            ) == .outer
        )
    }

    @Test
    func exhaustedNestedAndOuterScrollViewsLeaveTheEventUnchanged() {
        let hierarchy = makeScrollHierarchy(nestedOriginY: 500, outerScrollY: 500)
        hierarchy.nested.contentView.scroll(to: NSPoint(x: 0, y: 300))
        let hitView = hierarchy.outer.hitTest(NSPoint(x: 30, y: 30))
        #expect(hitView === hierarchy.textView)

        #expect(
            LitheScrollWheelRouting.destination(
                hitView: hitView,
                within: hierarchy.outer,
                deltaX: 0,
                deltaY: -10
            ) == .unchanged
        )
    }

    @Test
    func nestedEditorAtTopHandsUpwardScrollingToTheOuterPage() {
        let hierarchy = makeScrollHierarchy(nestedOriginY: 100, outerScrollY: 100)
        hierarchy.nested.contentView.scroll(to: .zero)
        let hitView = hierarchy.outer.hitTest(NSPoint(x: 30, y: 30))
        #expect(hitView === hierarchy.textView)

        #expect(
            LitheScrollWheelRouting.destination(
                hitView: hitView,
                within: hierarchy.outer,
                deltaX: 0,
                deltaY: 10
            ) == .outer
        )
    }

    @Test(arguments: [CGFloat(32), CGFloat(280)])
    func independentOverlayKeepsEventsEvenAtItsBoundary(width: CGFloat) throws {
        let hierarchy = makeScrollHierarchy(nestedOriginY: 100, outerScrollY: 100)
        let container = FlippedTestView(frame: hierarchy.outer.frame)
        container.addSubview(hierarchy.outer)
        // Both the narrow turn rail and the command list overlap the transcript,
        // but belong to a sibling responder chain rather than its document.
        let overlay = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let document = FlippedTestView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        overlay.documentView = document
        container.addSubview(overlay)
        let hitView = try #require(container.hitTest(NSPoint(x: 10, y: 30)))
        #expect(hitView === document)
        for origin in [CGFloat(0), CGFloat(100), CGFloat(700)] {
            overlay.contentView.scroll(to: NSPoint(x: 0, y: origin))
            for delta in [CGFloat(-10), CGFloat(10)] {
                #expect(LitheScrollWheelRouting.canScroll(hierarchy.outer, deltaX: 0, deltaY: delta))
                #expect(LitheScrollWheelRouting.destination(hitView: hitView, within: hierarchy.outer,
                    deltaX: 0, deltaY: delta) == .unchanged)
            }
        }
        #expect(LitheScrollWheelRouting.destination(hitView: nil, within: hierarchy.outer,
            deltaX: 0, deltaY: -10) == .unchanged)
        #expect(LitheScrollWheelRouting.destination(hitView: hierarchy.outer.documentView, within: hierarchy.outer,
            deltaX: 0, deltaY: -10) == .outer)
    }

    private func makeScrollHierarchy(
        nestedOriginY: CGFloat,
        outerScrollY: CGFloat
    ) -> (
        outer: NSScrollView,
        nested: NSScrollView,
        textView: NSTextView
    ) {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let outerDocument = FlippedTestView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        outer.documentView = outerDocument

        let nested = NSScrollView(frame: NSRect(
            x: 20,
            y: nestedOriginY,
            width: 300,
            height: 100
        ))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        nested.documentView = textView
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        outerDocument.addSubview(nested)
        outer.contentView.scroll(to: NSPoint(x: 0, y: outerScrollY))
        outer.reflectScrolledClipView(outer.contentView)
        outer.layoutSubtreeIfNeeded()
        return (outer, nested, textView)
    }
}

private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}
