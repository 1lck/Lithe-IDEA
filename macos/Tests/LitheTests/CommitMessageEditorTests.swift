import AppKit
import Testing
@testable import Lithe

@MainActor
@Suite("Commit message editor")
struct CommitMessageEditorTests {
    @Test func editorUsesOneTextOriginAndWrapsLongMessages() throws {
        let editor = CommitMessageTextView()
        editor.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        #expect(editor.textContainerOrigin == NSPoint(x: 8, y: 7))
        #expect(editor.textContainer?.lineFragmentPadding == 0)
        #expect(editor.textContainer?.widthTracksTextView == true)
        #expect(!editor.isHorizontallyResizable)
        #expect(editor.allowsUndo)
        editor.string = String(repeating: "commit message ", count: 20)
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        layout.ensureLayout(for: container)
        #expect(layout.usedRect(for: container).height > layout.defaultLineHeight(for: editor.font!))
    }

    @Test func outsideClickReleasesFocusButInsideClickKeepsIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.makeFirstResponder(nil); window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 200, height: 100))
        let editor = CommitMessageTextView()
        scroll.documentView = editor
        window.contentView?.addSubview(scroll)
        var focused = false
        editor.onFocus = { focused = $0 }
        #expect(window.makeFirstResponder(editor))
        #expect(focused)
        let inside = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        editor.releaseFocusForOutsideClick(inside)
        #expect(window.firstResponder === editor)
        let outside = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 300, y: 200), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1))
        editor.releaseFocusForOutsideClick(outside)
        #expect(window.firstResponder !== editor)
        #expect(!focused)
    }

}
