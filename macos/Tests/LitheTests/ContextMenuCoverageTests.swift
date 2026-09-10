import AppKit
import Testing
import LitheGitModule
@testable import Lithe

@Suite("Unified context menus")
@MainActor
struct ContextMenuCoverageTests {
    @Test
    func worktreeMenuRetainsClickedItemAcrossSelectionRefresh() throws {
        let clicked = worktree("feature")
        let other = worktree("other")
        let view = GitWorktreeListNSView()
        var received: (GitWorktreeListAction, String)?
        view.update(items: [clicked, other], selectedWorktreeID: other.id, onSelect: { _ in }) {
            received = ($0, $1.id)
        }
        let menu = view.contextMenuItems(for: clicked)
        // A selection-triggered refresh must not retarget an already-open menu.
        view.update(items: [other], selectedWorktreeID: other.id, onSelect: { _ in }) { _, _ in
            Issue.record("The open menu used a replacement callback")
        }
        try #require(menu.first { $0.title == "Copy Path" }).action()
        #expect(received?.0 == .copyPath)
        #expect(received?.1 == clicked.id)
    }

    @Test
    func worktreeMenuPreservesProtectionAndBusyStates() throws {
        let view = GitWorktreeListNSView()
        let primary = worktree("primary", primary: true, current: true)
        let locked = worktree("locked", locked: true)
        let stale = worktree("stale", prunable: true)
        view.update(items: [primary, locked, stale], selectedWorktreeID: nil, onSelect: { _ in })
        let primaryMenu = view.contextMenuItems(for: primary)
        #expect(try #require(primaryMenu.first { $0.title == "Lock Worktree" }).isEnabled == false)
        #expect(try #require(primaryMenu.first { $0.title == "Remove Worktree…" }).isEnabled == false)
        #expect(try #require(primaryMenu.first { $0.title == "Prune Stale Records" }).isEnabled)
        let lockedMenu = view.contextMenuItems(for: locked)
        #expect(try #require(lockedMenu.first { $0.title == "Unlock Worktree" }).isEnabled)
        #expect(try #require(lockedMenu.first { $0.title == "Remove Worktree…" }).isEnabled == false)
        let staleMenu = view.contextMenuItems(for: stale)
        #expect(try #require(staleMenu.first { $0.title == "Open in Current Window" }).isEnabled == false)
        #expect(try #require(staleMenu.first { $0.title == "Open in New Window" }).isEnabled == false)
        view.update(items: [locked, stale], selectedWorktreeID: nil, isPerformingWorktreeOperation: true, onSelect: { _ in })
        let busyMenu = view.contextMenuItems(for: locked)
        #expect(try #require(busyMenu.first { $0.title == "Unlock Worktree" }).isEnabled == false)
        #expect(try #require(busyMenu.first { $0.title == "Prune Stale Records" }).isEnabled == false)
        #expect(try #require(busyMenu.first { $0.title == "Copy Path" }).isEnabled)
    }

    @Test
    func commitMenuRetainsActionOwnerAndClickedCommit() throws {
        let commit = GitCommit(
            hash: "abcdef123456", shortHash: "abcdef1", parentHashes: [],
            authorName: "Test", authorEmail: "test@example.invalid", date: "", subject: "Test", decorations: ""
        )
        var received: [String] = []
        let menu = GitGraphRowActions(
            onSelect: { _ in Issue.record("Right click must not check out or change selection") },
            onCherryPick: { received.append("cherry:\($0.hash)") },
            onRevert: { received.append("revert:\($0.hash)") },
            onReset: { received.append("reset:\($0.hash)") },
            onCreateTag: { received.append("tag:\($0.hash)") }
        ).contextMenuItems(for: commit)
        for title in ["New Tag…", "Cherry-pick Commit…", "Revert Commit…", "Reset Current Branch to Here…"] {
            try #require(menu.first { $0.title == title }).action()
        }
        #expect(received == ["tag:abcdef123456", "cherry:abcdef123456", "revert:abcdef123456", "reset:abcdef123456"])
    }

    @Test
    func contextMenusCannotSilentlyBypassSharedStyle() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(source.range(of: #"\.contextMenu\s*[({]"#, options: .regularExpression) == nil,
                    "Use the shared context menu in \(file.lastPathComponent)")
            // Completion and source-action pickers are caret popups, not right-click menus.
            // All other AppKit menu construction must use the shared presenter.
            let withoutCaretPickers = source.replacingOccurrences(
                of: #"(?ms)^    func presentLanguage(?:Completions|CodeActions)\(.*?^    \}"#,
                with: "", options: .regularExpression
            )
            #expect(withoutCaretPickers.range(of: #"\bNSMenu\s*\("#, options: .regularExpression) == nil,
                    "Audit the native menu entry in \(file.lastPathComponent)")
        }
    }

    @Test
    func windowKeyboardSkipsDisabledItemsAndNavigatesSubmenus() throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        var calls: [String] = []
        let items: [LitheContextMenuItem] = [
            .separator, .action("Disabled", isEnabled: false) { calls.append("disabled") },
            .action("Open") { calls.append("open") },
            .submenu("Move", items: [.separator, .action("Disabled", isEnabled: false) {},
                                     .action("Folder") { calls.append("folder") }])
        ]
        func show() throws -> NSWindow {
            presenter.show(items: items, at: NSPoint(x: 200, y: 300), appearance: nil, locale: Locale(identifier: "en"))
            return try #require(NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel") })
        }
        var window = try show()
        try sendKey(125, to: window)
        try sendKey(36, to: window)
        #expect(calls == ["open"])
        window = try show()
        try sendKey(126, to: window)
        try sendKey(124, to: window)
        try sendKey(123, to: window)
        try sendKey(124, to: window)
        try sendKey(36, to: window)
        #expect(calls == ["open", "folder"])
    }

    @Test
    func longSubmenusStayOnScreenAndLastItemCanExecute() throws {
        let screen = try #require(NSScreen.main).visibleFrame
        for count in [20, 100] {
            let presenter = LitheContextMenuPresenter()
            defer { presenter.dismiss() }
            var selected = false
            let folders = (0..<count).map { index in LitheContextMenuItem.action("Folder \(index)") {} }
                + [.action("New Folder") { selected = true }]
            presenter.show(items: [.submenu("Move to Folder", items: folders)],
                           at: NSPoint(x: screen.midX, y: screen.minY + 250), appearance: nil,
                           locale: Locale(identifier: "en"))
            let window = try #require(NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel") })
            try sendKey(125, to: window)
            try sendKey(124, to: window)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(screen.contains(window.frame))
            try sendKey(126, to: window)
            try sendKey(36, to: window)
            #expect(selected)
        }
    }

    @Test
    func dynamicBranchTitleUsesExistingChineseFormat() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundle = try #require(Bundle(url: resources.appendingPathComponent("zh-Hans.lproj")))
        #expect(gitNewBranchMenuTitle("feature-demo", locale: Locale(identifier: "zh-Hans"), bundle: bundle)
                == "从“feature-demo”新建分支…")
    }

    private func sendKey(_ code: UInt16, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func worktree(
        _ name: String, primary: Bool = false, current: Bool = false,
        locked: Bool = false, prunable: Bool = false
    ) -> GitWorktreeListItem {
        GitWorktreeListItem(worktree: GitWorktree(
            path: "/test/worktrees/\(name)", head: "abcdef", branch: "refs/heads/\(name)",
            isCurrent: current, isPrimary: primary, isBare: false, isDetached: false,
            isLocked: locked, lockReason: nil, isPrunable: prunable, pruneReason: nil
        ), status: .available)
    }
}
