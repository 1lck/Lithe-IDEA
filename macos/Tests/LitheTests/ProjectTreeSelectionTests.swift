import AppKit
import Foundation
import LitheCoreContracts
import SwiftUI
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

    @Test
    @MainActor
    func consumedTreeShortcutIsNotAlsoDeliveredToTheEditor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tree = ProjectTreeKeyboardCommandView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        defer { tree.removeMonitor(); window.close() }
        window.contentView?.addSubview(tree)
        var selections = 0
        tree.selectAllItems = { selections += 1 }

        // The installed monitor returns this value to AppKit; a non-nil result
        // means the editor would also select all text or paste the clipboard.
        _ = ProjectTreeKeyboardCommandView.monitorResult(for: try mouseDown(at: NSPoint(x: 50, y: 50), in: window), view: tree)
        #expect(ProjectTreeKeyboardCommandView.monitorResult(for: try commandKey("a", in: window), view: tree) == nil)
        #expect(selections == 1)
        #expect(ProjectTreeKeyboardCommandView.monitorResult(for: try commandKey("a", in: window), view: nil) != nil)
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
    @MainActor
    func modifiedRowClicksReachTheOverlayThroughWindowDispatch() throws {
        let rows = ["folder", "a", "b", "c"]
        var selection = ProjectTreeSelection()
        var activated: [String] = []
        let rowHeight: CGFloat = 22
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: rowHeight * CGFloat(rows.count)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        // Mirrors FileNodeRow: the Button selects and opens a file or folds a
        // folder, and the overlay handles modified clicks.
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(rows, id: \.self) { row in
                Button {
                    selection.select(row, visiblePaths: rows, extending: false, toggling: false)
                    activated.append(row)
                } label: {
                    Color.clear.frame(width: 240, height: rowHeight).contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .overlay {
                    ProjectTreeModifiedClick { flags in
                        selection.select(row, visiblePaths: rows, extending: flags.contains(.shift),
                                         toggling: flags.contains(.command))
                    }
                }
            }
        })
        // Hosting views hit-test only in an on-screen window; it never becomes key.
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        // The window hit-tests each event and routes it to the overlay or the
        // Button as in the app; only the current-event lookup is substituted.
        var dispatching: NSEvent?
        for overlay in try #require(window.contentView).descendants.compactMap({ $0 as? ProjectTreeModifiedClickView }) {
            overlay.currentEvent = { dispatching }
        }
        func click(_ index: Int, _ flags: NSEvent.ModifierFlags) throws {
            let point = NSPoint(x: 50, y: rowHeight * (CGFloat(rows.count - index) - 0.5))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                dispatching = event
                window.sendEvent(event)
            }
            dispatching = nil
        }

        // A plain click goes to the Button and sets the range anchor.
        try click(1, [])
        #expect(activated == ["a"])
        #expect(selection.paths == ["a"])
        // Shift extends forward and backward, ⌘ toggles; none of these clicks
        // reach the Button, so files stay closed and the folder stays as is.
        try click(3, .shift)
        #expect(selection.paths == ["a", "b", "c"])
        try click(2, .command)
        #expect(selection.paths == ["a", "c"])
        try click(3, [])
        try click(1, .shift)
        #expect(selection.paths == ["a", "b", "c"])
        try click(0, .command)
        #expect(selection.paths == ["folder", "a", "b", "c"])
        #expect(activated == ["a", "c"])

        // Control-click passes through the overlay to the row below, where
        // FileNodeRow's context menu capture handles it.
        try click(2, [.control, .shift])
        #expect(activated == ["a", "c", "b"])
    }

    @Test
    func rightClickPreservesTheGroupOnlyForSelectedRows() {
        let root = FileNode(url: URL(fileURLWithPath: "/p"), isDirectory: true, children: [
            FileNode(url: URL(fileURLWithPath: "/p/a"), isDirectory: false, children: nil),
            FileNode(url: URL(fileURLWithPath: "/p/b"), isDirectory: false, children: nil)
        ])
        var selection = ProjectTreeSelection()
        selection.selectAll(in: root)
        selection.selectForContextMenu("/p/a")
        #expect(selection.paths == ["/p/a", "/p/b"])
        selection.selectForContextMenu("/p/c")
        #expect(selection.paths == ["/p/c"])
        #expect(selection.anchorPath == "/p/c")
    }

    @Test
    func selectAllUsesTheFocusedRowsSiblings() {
        func node(_ path: String, _ children: [FileNode]? = nil, collapsed: [String] = []) -> FileNode {
            FileNode(url: URL(fileURLWithPath: path), isDirectory: children != nil, children: children,
                     collapsedAncestorPaths: collapsed)
        }
        // `src/com/acme` is a compacted package shown directly below `src`.
        let root = node("/p", [
            node("/p/dest", [node("/p/dest/a.txt")]),
            node("/p/dest copy", [node("/p/dest copy/a.txt"), node("/p/dest copy/b.txt")]),
            node("/p/src", [node("/p/src/com/acme", [node("/p/src/com/acme/App.java")], collapsed: ["/p/src/com"])]),
            node("/p/alpha.txt"), node("/p/gamma.txt")
        ])
        let topLevel: Set<String> = ["/p/dest", "/p/dest copy", "/p/src", "/p/alpha.txt", "/p/gamma.txt"]
        var selection = ProjectTreeSelection()
        func selectAll(focusing path: String) -> Set<String> {
            selection.select(path, visiblePaths: [path], extending: false, toggling: false)
            selection.selectAll(in: root)
            return selection.paths
        }

        // A file inside a folder selects that folder's items only.
        #expect(selectAll(focusing: "/p/dest copy/a.txt") == ["/p/dest copy/a.txt", "/p/dest copy/b.txt"])
        #expect(selection.focusedPath == "/p/dest copy/a.txt")
        // A folder selects the items beside it, not its own contents.
        #expect(selectAll(focusing: "/p/dest copy") == topLevel)
        #expect(selectAll(focusing: "/p/alpha.txt") == topLevel)
        // A similarly named sibling folder stays out of the scope.
        #expect(selectAll(focusing: "/p/dest/a.txt") == ["/p/dest/a.txt"])
        // Compacted packages use their displayed parent.
        #expect(selectAll(focusing: "/p/src/com/acme") == ["/p/src/com/acme"])
        #expect(selectAll(focusing: "/p/src/com/acme/App.java") == ["/p/src/com/acme/App.java"])
        // Selected folders show their contents as selected too, without adding
        // them to the action set or matching a similarly named sibling.
        #expect(selectAll(focusing: "/p/dest copy") == topLevel)
        #expect(selection.covers("/p/dest copy/a.txt"))
        #expect(selection.covers("/p/src/com/acme/App.java"))
        #expect(!selection.paths.contains("/p/dest copy/a.txt"))
        // Right-clicking a covered row keeps the group for the batch menu.
        selection.selectForContextMenu("/p/dest copy/a.txt")
        #expect(selection.paths == topLevel)
        // Inside a single selected folder, right-click targets the clicked row.
        selection.select("/p/dest", visiblePaths: ["/p/dest"], extending: false, toggling: false)
        #expect(selection.covers("/p/dest/a.txt") && !selection.covers("/p/dest copy/a.txt"))
        selection.selectForContextMenu("/p/dest/a.txt")
        #expect(selection.paths == ["/p/dest/a.txt"])
        // The project row, or no focus, selects the top-level items.
        #expect(selectAll(focusing: "/p") == topLevel)
        var unfocused = ProjectTreeSelection()
        unfocused.selectAll(in: root)
        #expect(unfocused.paths == topLevel)
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
        selection.select(last.url.path, visiblePaths: visible, extending: false, toggling: false)
        selection.select(child.url.path, visiblePaths: visible, extending: false, toggling: true)
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

private extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
