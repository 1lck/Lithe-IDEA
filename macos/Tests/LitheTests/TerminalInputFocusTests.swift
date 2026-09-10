import AppKit
import MetalKit
import SwiftTerm
import Testing
@testable import Lithe

@Suite("Terminal input focus")
@MainActor
struct TerminalInputFocusTests {
    @Test
    func coreGraphicsCaretIsRemovedOutsideKeyboardOwner() throws {
        let window = CursorFocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = CodeTextView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)
        try terminal.setUseMetal(false)
        #expect(window.makeFirstResponder(terminal))
        terminal.showCursor(source: terminal.terminal)
        let focusedChildren = Set(terminal.subviews.map(ObjectIdentifier.init))

        #expect(window.makeFirstResponder(editor))
        let inactiveChildren = Set(terminal.subviews.map(ObjectIdentifier.init))
        #expect(focusedChildren.subtracting(inactiveChildren).count == 1,
                "The fallback caret must be removed, not left as an inactive outline")
        #expect(window.makeFirstResponder(terminal))
        #expect(Set(terminal.subviews.map(ObjectIdentifier.init)) == focusedChildren)

        terminal.terminal.hideCursor()
        #expect(window.makeFirstResponder(editor))
        #expect(window.makeFirstResponder(terminal))
        #expect(Set(terminal.subviews.map(ObjectIdentifier.init)) == inactiveChildren,
                "Focus must not reveal a cursor hidden by the shell")
    }

    @Test
    func onlyKeyboardOwnerDrawsVisibleMetalCursorAndPreservesShellStyle() throws {
        let window = CursorFocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = CodeTextView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        let content = try #require(window.contentView)
        content.addSubview(terminal)
        content.addSubview(editor)
        let view = MTKView(frame: terminal.bounds, device: nil)
        let renderer = CursorDrawingRecorder()
        let focusDelegate = TerminalMetalFocusDelegate(view: view, terminalView: terminal, renderer: renderer)
        let requestedColor = NSColor.systemBlue
        terminal.caretColor = requestedColor

        for requestedStyle in [CursorStyle.blinkBlock, .blinkBar, .blinkUnderline, .steadyBar] {
            terminal.terminal.setCursorStyle(requestedStyle)
            #expect(window.makeFirstResponder(editor))
            // Even a stale terminal flag must not animate a background panel.
            terminal.hasFocus = true
            #expect(!terminal.hasFocus)
            renderer.onDraw = {
                #expect(terminal.terminal.options.cursorStyle == .steadyBlock)
                #expect(terminal.caretColor.alphaComponent == 0)
            }
            focusDelegate.draw(in: view)
            #expect(terminal.terminal.options.cursorStyle == requestedStyle)
            #expect(terminal.caretColor == requestedColor)

            #expect(window.makeFirstResponder(terminal))
            #expect(terminal.hasFocus)
            renderer.onDraw = {
                #expect(terminal.terminal.options.cursorStyle == requestedStyle)
                #expect(terminal.caretColor == requestedColor)
            }
            focusDelegate.draw(in: view)
        }
        #expect(renderer.drawCount == 8)
        let resized = CGSize(width: 640, height: 320)
        focusDelegate.mtkView(view, drawableSizeWillChange: resized)
        #expect(renderer.drawableSize == resized)
        window.reportsKeyWindow = false
        renderer.onDraw = {
            #expect(terminal.terminal.options.cursorStyle == .steadyBlock)
            #expect(terminal.caretColor.alphaComponent == 0)
        }
        focusDelegate.draw(in: view)
        #expect(!terminal.hasFocus)
    }

    @Test
    func focusChangesInvalidateTheMetalCursorWithoutShellOutput() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let renderer = CursorInvalidationRecordingView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)
        renderer.requestedDisplay = false

        terminal.hasFocus = true
        #expect(renderer.requestedDisplay)
        renderer.requestedDisplay = false
        terminal.hasFocus = false
        #expect(renderer.requestedDisplay, "The inactive cursor must repaint without waiting for shell output")
    }

    @Test
    func renderingSurfaceRoutesClicksToTerminal() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // Reproduce the renderer's hit-testing hierarchy without requiring a GPU or shell.
        let renderer = CursorInvalidationRecordingView(frame: terminal.bounds, device: nil)
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
    func windowFocusChangesInvalidateBothCursorSurfaces() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = CodeTextView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)
        let renderer = CursorInvalidationRecordingView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)
        #expect(window.makeFirstResponder(editor))

        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            editor.needsDisplay = false
            renderer.requestedDisplay = false
            // Deliver the native lifecycle boundary directly; no real focus-stealing
            // window activation or wall-clock blink interval is needed by the test.
            NotificationCenter.default.post(name: name, object: window)
            #expect(editor.needsDisplay)
            #expect(renderer.requestedDisplay)
        }

        terminal.removeFromSuperview()
        editor.removeFromSuperview()
        editor.needsDisplay = false
        renderer.requestedDisplay = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!editor.needsDisplay, "Detached editors must release their window observers")
        #expect(!renderer.requestedDisplay, "Detached terminals must release their window observers")
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
        let editor = CodeTextView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        editor.needsDisplay = false
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        terminal.mouseDown(with: click)

        #expect(window.firstResponder === terminal)
        #expect(editor.needsDisplay, "Losing focus must immediately erase the editor's painted caret")
        editor.needsDisplay = false
        #expect(window.makeFirstResponder(editor))
        #expect(editor.needsDisplay, "Returning to the editor must restore its caret")
    }
}

@MainActor
private final class CursorFocusTestWindow: NSWindow {
    var reportsKeyWindow = true
    override var isKeyWindow: Bool { reportsKeyWindow }
}

@MainActor
private final class CursorInvalidationRecordingView: MTKView {
    var requestedDisplay = false

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        requestedDisplay = true
        super.setNeedsDisplay(invalidRect)
    }
}

@MainActor
private final class CursorDrawingRecorder: NSObject, MTKViewDelegate {
    var onDraw: () -> Void = {}
    var drawCount = 0
    var drawableSize: CGSize?

    func draw(in view: MTKView) {
        drawCount += 1
        onDraw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }
}
