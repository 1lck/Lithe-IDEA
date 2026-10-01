import AppKit
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

struct ProjectTreeSelectionTests {
    @Test
    @MainActor
    func nativeClipboardRoundTripsMultipleFilesAndIgnoresText() {
        let pasteboard = NSPasteboard(name: .init("lithe-file-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/workspace/a.txt"), URL(fileURLWithPath: "/workspace/b.txt")]
        #expect(MacFileClipboard.write(urls, to: pasteboard))
        #expect(MacFileClipboard.read(from: pasteboard) == urls)
        pasteboard.clearContents()
        pasteboard.setString("ordinary editor text", forType: .string)
        #expect(MacFileClipboard.read(from: pasteboard).isEmpty)
        #expect(!MacFileClipboard.write([], to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "ordinary editor text")
    }

    @Test
    @MainActor
    func treeShortcutsYieldToKeyboardFocusMovedAfterTheTreeClick() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tree = ProjectTreeKeyboardCommandView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let other = ProjectTreeFocusTestView(frame: NSRect(x: 200, y: 0, width: 200, height: 150))
        let search = NSTextField(frame: NSRect(x: 200, y: 200, width: 180, height: 24))
        let filter = NSTextField(frame: NSRect(x: 200, y: 160, width: 180, height: 24))
        defer { tree.removeMonitor(); window.makeFirstResponder(nil); window.close() }
        [tree, other, search, filter].forEach { window.contentView?.addSubview($0) }
        var copies = 0
        tree.copyItems = { copies += 1 }

        // Clicking the tree claims ⌘C even though the tree has no focusable view.
        #expect(tree.handle(try mouseDown(at: NSPoint(x: 50, y: 50), in: window)) != nil)
        #expect(tree.handle(try commandKey("c", in: window)) == nil)
        #expect(copies == 1)

        // A text field focused afterwards, such as Search Everywhere, keeps ⌘C/⌘V/⌘A.
        #expect(window.makeFirstResponder(search))
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        #expect(tree.handle(try commandKey("c", in: window)) != nil)
        #expect(tree.handle(try commandKey("v", in: window)) != nil)
        #expect(copies == 1)

        // Ownership stays released until the tree is clicked again.
        #expect(window.makeFirstResponder(nil))
        #expect(tree.handle(try commandKey("c", in: window)) != nil)
        _ = tree.handle(try mouseDown(at: NSPoint(x: 50, y: 50), in: window))
        #expect(tree.handle(try commandKey("c", in: window)) == nil)
        #expect(copies == 2)

        // Any other keyboard focus change after the first shortcut also releases it.
        #expect(window.makeFirstResponder(other))
        #expect(tree.handle(try commandKey("c", in: window)) != nil)
        #expect(copies == 2)

        // Fields share one field editor, so focusing another field still releases.
        #expect(window.makeFirstResponder(filter))
        _ = tree.handle(try mouseDown(at: NSPoint(x: 50, y: 50), in: window))
        #expect(tree.handle(try commandKey("c", in: window)) == nil)
        #expect(copies == 3)
        #expect(window.makeFirstResponder(search))
        #expect(tree.handle(try commandKey("c", in: window)) != nil)
        #expect(copies == 3)

        // A click outside the tree returns shortcuts to the clicked area.
        _ = tree.handle(try mouseDown(at: NSPoint(x: 50, y: 50), in: window))
        _ = tree.handle(try mouseDown(at: NSPoint(x: 300, y: 50), in: window))
        #expect(tree.handle(try commandKey("c", in: window)) != nil)
        #expect(copies == 3)
    }

    @MainActor
    private func mouseDown(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func commandKey(_ character: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
    }

    @Test
    func modifiedClicksToggleAndShiftKeepsItsAnchor() {
        var selection = ProjectTreeSelection()
        let rows = ["a", "b", "c", "d"]
        selection.select("b", visiblePaths: rows, extending: false, toggling: false)
        selection.select("d", visiblePaths: rows, extending: true, toggling: false)
        #expect(selection.paths == ["b", "c", "d"])
        selection.select("a", visiblePaths: rows, extending: true, toggling: false)
        #expect(selection.paths == ["a", "b"])
        selection.select("d", visiblePaths: rows, extending: false, toggling: true)
        #expect(selection.paths == ["a", "b", "d"])
        selection.select("b", visiblePaths: rows, extending: false, toggling: true)
        #expect(selection.paths == ["a", "d"])
    }

    @Test
    func rightClickPreservesTheGroupOnlyForSelectedRows() {
        var selection = ProjectTreeSelection()
        selection.selectAll(visiblePaths: ["a", "b"])
        selection.selectForContextMenu("a")
        #expect(selection.paths == ["a", "b"])
        selection.selectForContextMenu("c")
        #expect(selection.paths == ["c"])
        #expect(selection.anchorPath == "c")
    }

    @Test
    func collapsedChildrenAreExcludedFromRangesAndSelection() {
        let rootURL = URL(fileURLWithPath: "/workspace")
        let child = FileNode(url: rootURL.appendingPathComponent("folder/hidden"), isDirectory: false, children: nil)
        let folder = FileNode(url: rootURL.appendingPathComponent("folder"), isDirectory: true, children: [child])
        let last = FileNode(url: rootURL.appendingPathComponent("last"), isDirectory: false, children: nil)
        let root = FileNode(url: rootURL, isDirectory: true, children: [folder, last])
        let visible = ProjectTreeSelection.visibleNodes(in: root, expandedPaths: [rootURL.path]).map { $0.url.path }
        #expect(visible == [rootURL.path, folder.url.path, last.url.path])
        var selection = ProjectTreeSelection()
        selection.selectAll(visiblePaths: visible + [child.url.path])
        selection.retain(visiblePaths: visible)
        #expect(!selection.paths.contains(child.url.path))
        #expect(selection.focusedPath == nil)
        selection.select(folder.url.path, visiblePaths: visible, extending: false, toggling: false)
        selection.select(last.url.path, visiblePaths: visible, extending: true, toggling: false)
        #expect(selection.paths == [folder.url.path, last.url.path])
    }
}

/// A non-text responder standing in for a focused editor or panel.
private final class ProjectTreeFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
