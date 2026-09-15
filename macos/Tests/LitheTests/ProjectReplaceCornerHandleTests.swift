import AppKit
import Testing
@testable import Lithe

@Suite("Replacement corner cursor")
@MainActor
struct ProjectReplaceCornerHandleTests {
    @Test
    func allCornersKeepResizeCursorWhenTheHandleMovesAndPointerLeaves() throws {
        let previous = NSCursor.current
        defer { previous.set() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handle = ProjectReplaceCornerHandleView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        defer { handle.endTracking(); window.close() }
        try #require(window.contentView).addSubview(handle)
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        for corner in ProjectReplacePanelGeometry.Corner.allCases {
            handle.corner = corner
            let cursor = handle.resizeCursor
            #expect(cursor !== NSCursor.crosshair && cursor !== NSCursor.arrow)
            handle.mouseEntered(with: exit)
            #expect(NSCursor.current === cursor)
            var translation: CGSize?
            handle.onChange = { translation = $0 }
            handle.mouseDown(with: try event(.leftMouseDown, x: 10, y: 200))
            #expect(!window.areCursorRectsEnabled)
            // The corner moves with the resized panel; leaving its old hit target must not reset the cursor.
            handle.frame.origin = NSPoint(x: 80, y: 90)
            handle.mouseExited(with: exit)
            #expect(NSCursor.current === cursor)
            handle.mouseDragged(with: try event(.leftMouseDragged, x: 50, y: 170))
            #expect(NSCursor.current === cursor)
            #expect(translation == CGSize(width: 40, height: 30))
            handle.mouseUp(with: try event(.leftMouseUp, x: 50, y: 170))
            #expect(window.areCursorRectsEnabled)
        }
        handle.mouseDown(with: try event(.leftMouseDown, x: 10, y: 200))
        handle.removeFromSuperview()
        #expect(window.areCursorRectsEnabled)
    }
}
