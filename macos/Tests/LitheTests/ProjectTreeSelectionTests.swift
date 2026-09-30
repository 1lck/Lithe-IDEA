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
