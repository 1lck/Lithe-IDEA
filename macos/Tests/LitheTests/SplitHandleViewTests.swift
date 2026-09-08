import AppKit
import Testing
import SwiftUI
@testable import Lithe

@Suite("Split handle updates")
struct SplitHandleViewTests {
    @Test
    func pendingDragUpdatesCoalesceToNewestTranslation() {
        var buffer = FrameCoalescedDragUpdateBuffer()

        let scheduledFirstDelivery = buffer.submit(12)
        let scheduledSecondDelivery = buffer.submit(28)
        let scheduledThirdDelivery = buffer.submit(41)
        let deliveredTranslation = buffer.takePendingValue()

        #expect(scheduledFirstDelivery)
        #expect(!scheduledSecondDelivery)
        #expect(!scheduledThirdDelivery)
        #expect(deliveredTranslation == 41)
        #expect(!buffer.hasScheduledDelivery)
    }

    @Test
    func cancelledDragUpdateDoesNotLeakIntoNextDrag() {
        var buffer = FrameCoalescedDragUpdateBuffer()
        let scheduledCancelledDelivery = buffer.submit(24)
        #expect(scheduledCancelledDelivery)

        buffer.cancel()

        #expect(buffer.pendingValue == nil)
        #expect(!buffer.hasScheduledDelivery)
        let scheduledNextDelivery = buffer.submit(7)
        let deliveredTranslation = buffer.takePendingValue()
        #expect(scheduledNextDelivery)
        #expect(deliveredTranslation == 7)
    }

    @MainActor
    @Test
    func verticalDividerKeepsFullHeightAndCenteredHitWidth() throws {
        let hosting = NSHostingView(rootView: HStack(spacing: 0) {
            Color.clear.frame(width: 100)
            SplitHandleView(
                axis: .horizontal, showsIdleDivider: false,
                onDragStarted: {}, onDragChanged: { _ in }, onDragEnded: { _ in }
            )
            SplitHandleEditorFixture()
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 305, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let region = try #require(cursorRegion(in: hosting))
        let rect = region.convert(region.bounds, to: hosting)
        #expect(rect.width == 10)
        #expect(rect.height == 180)
        // SwiftUI snaps half-point origins on a 1x hosting surface.
        #expect(abs(rect.midX - 102.5) <= 0.5)
        #expect(rect.minX < 100 && rect.maxX > 105)
        #expect(hosting.hitTest(NSPoint(x: rect.midX, y: rect.midY)) === region,
                "AppKit must deliver cursor events to the divider, not its hosting view")
        for x in [rect.minX + 1, rect.maxX - 1] {
            #expect(hosting.hitTest(NSPoint(x: x, y: rect.midY)) === region)
        }
        #expect(region.resizeCursor === NSCursor.resizeLeftRight)

        hosting.frame.size.height = 320
        hosting.layoutSubtreeIfNeeded()
        #expect(region.bounds.height == 320)
    }

    @MainActor
    @Test
    func horizontalDividerKeepsFullWidthAndCenteredHitHeight() throws {
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            SplitHandleEditorFixture().frame(height: 100)
            SplitHandleView(
                axis: .vertical, showsIdleDivider: false,
                onDragStarted: {}, onDragChanged: { _ in }, onDragEnded: { _ in }
            )
            Color.clear
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 205),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let region = try #require(cursorRegion(in: hosting))
        let rect = region.convert(region.bounds, to: hosting)
        #expect(rect.width == 300)
        #expect(rect.height == 10)
        #expect(abs(rect.midY - 102.5) <= 0.5)
        #expect(region.resizeCursor === NSCursor.resizeUpDown)
        #expect(hosting.hitTest(NSPoint(x: rect.midX, y: rect.midY)) === region,
                "The bottom divider must own its native hit target too")

        for y in [rect.minY + 1, rect.maxY - 1] {
            #expect(hosting.hitTest(NSPoint(x: rect.midX, y: y)) === region)
        }
        hosting.frame.size.width = 500
        hosting.layoutSubtreeIfNeeded()
        #expect(region.bounds.width == 500)
    }

    @MainActor
    @Test
    func editorExitDoesNotOverwriteEitherResizeCursor() throws {
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let exit = try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: NSPoint(x: 105, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        let region = SplitHandleInteractionView()
        for cursor in [NSCursor.resizeLeftRight, NSCursor.resizeUpDown] {
            region.axis = cursor === NSCursor.resizeLeftRight ? .horizontal : .vertical
            // AppKit may deliver the old view's exit after the new view's entry.
            region.mouseEntered(with: exit)
            editor.mouseExited(with: exit)
            #expect(NSCursor.current === cursor)
        }
    }

    @MainActor
    @Test
    func editorIgnoresLatePointerEventsOutsideItsHitTarget() throws {
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        try #require(window.contentView).addSubview(editor)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 150, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))
        for cursor in [NSCursor.resizeLeftRight, NSCursor.resizeUpDown] {
            cursor.set()
            editor.mouseMoved(with: event)
            editor.cursorUpdate(with: event)
            #expect(NSCursor.current === cursor)
        }
    }

    @MainActor
    @Test
    func nativeDragKeepsScreenTranslationWhenTheHandleMoves() throws {
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let handle = SplitHandleInteractionView(frame: NSRect(x: 45, y: 0, width: 10, height: 200))
        try #require(window.contentView).addSubview(handle)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0
            ))
        }
        for axis in [LitheSplitAxis.horizontal, .vertical] {
            handle.axis = axis
            var starts = 0
            var changes: [CGFloat] = []
            var ends: [CGFloat] = []
            handle.onDragStarted = { starts += 1 }
            handle.onDragChanged = { changes.append($0) }
            handle.onDragEnded = { ends.append($0) }
            handle.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 50, y: 150)))
            // Layout shifts the handle before the next pointer event.
            handle.frame.origin = NSPoint(x: 70, y: 30)
            handle.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 80, y: 120)))
            let release = try event(.leftMouseUp, NSPoint(x: 95, y: 105))
            handle.mouseUp(with: release)
            handle.mouseUp(with: release)
            #expect(starts == 1)
            #expect(changes == [30])
            #expect(ends == [45])
            handle.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 100, y: 100)))
            handle.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 90, y: 110)))
            #expect(starts == 2)
            #expect(ends == [45, -10])
        }
    }

    @MainActor
    private func cursorRegion(in view: NSView) -> SplitHandleInteractionView? {
        if let region = view as? SplitHandleInteractionView { return region }
        return view.subviews.lazy.compactMap { cursorRegion(in: $0) }.first
    }

}

private struct SplitHandleEditorFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
