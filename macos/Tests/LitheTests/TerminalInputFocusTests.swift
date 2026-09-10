import AppKit
import MetalKit
import Testing
@testable import Lithe

@Suite("Terminal input focus")
@MainActor
struct TerminalInputFocusTests {
    @Test
    func renderingSurfaceRoutesClicksToTerminal() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // Reproduce the renderer's hit-testing hierarchy without requiring a GPU or shell.
        let renderer = MTKView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)

        #expect(terminal.hitTest(NSPoint(x: 100, y: 100)) === terminal)
        #expect(terminal.hitTest(NSPoint(x: -1, y: 100)) == nil)
    }

    @Test
    func scrollbarRemainsInteractiveAboveRenderer() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.addSubview(MTKView(frame: terminal.bounds, device: nil))
        let scroller = NSScroller(frame: NSRect(x: 380, y: 0, width: 20, height: 200))
        terminal.addSubview(scroller)

        #expect(terminal.hitTest(NSPoint(x: 390, y: 100)) === scroller)
    }

    @Test
    func clickingTerminalRestoresFocusAfterAnotherControl() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = NSTextView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        terminal.mouseDown(with: click)

        #expect(window.firstResponder === terminal)
    }
}
