import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Commit message editor")
struct CommitMessageEditorTests {
    @Test func composingCancellingAndCommittingRedrawTheWholePlaceholder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = CommitMessageTextView()
        editor.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        window.contentView = editor
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(editor))
        func placeholderPixels() throws -> Int {
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            let background = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: 0))
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in bitmap.pixelsWide / 4..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y))
                    if abs(color.redComponent - background.redComponent) > 0.05
                        || abs(color.greenComponent - background.greenComponent) > 0.05
                        || abs(color.blueComponent - background.blueComponent) > 0.05 { count += 1 }
                }
            }
            return count
        }
        #expect(try placeholderPixels() > 10)
        editor.needsDisplay = false
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        // Short composition must invalidate the end of the old placeholder too.
        #expect(editor.needsToDraw(NSRect(x: 160, y: 3, width: 10, height: 20)))
        #expect(try placeholderPixels() == 0)
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        #expect(try placeholderPixels() > 10)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "你")
        #expect(!editor.hasMarkedText())
        #expect(try placeholderPixels() == 0)
    }

    @Test func editorUsesOneTextOriginAndWrapsLongMessages() throws {
        let editor = CommitMessageTextView()
        editor.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        #expect(editor.textContainerOrigin == NSPoint(x: 9, y: 3))
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

    @Test(arguments: [ColorScheme.dark, .light])
    func nativeEditorUsesRegularEditorFontAndSharedPlaceholderColor(scheme: ColorScheme) throws {
        let host = NSHostingView(rootView: CommitMessageEditor(text: .constant(""), focused: .constant(false))
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.makeFirstResponder(nil); window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findEditor(in view: NSView) -> CommitMessageTextView? {
            if let editor = view as? CommitMessageTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        let editor = try #require(findEditor(in: host))
        let font = try #require(editor.font)
        #expect(font.pointSize == 13)
        #expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        appearance.performAsCurrentDrawingAppearance {
            let color = editor.placeholderColor.usingColorSpace(.sRGB)!
            #expect(abs(color.redComponent - 115.0 / 255) < 0.01)
            #expect(abs(color.greenComponent - 118.0 / 255) < 0.01)
            #expect(abs(color.blueComponent - 124.0 / 255) < 0.01)
            #expect(editor.insertionPointColor.usingColorSpace(.sRGB) == editor.textColor?.usingColorSpace(.sRGB))
        }
        // Placeholder remains visible while focused, and is not the document's content.
        #expect(window.makeFirstResponder(editor))
        #expect(editor.string.isEmpty)
        #expect(editor.textContainerOrigin == NSPoint(x: 9, y: 3))
    }

}
