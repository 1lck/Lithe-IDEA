import AppKit
import Testing
import SwiftUI
import LitheGitModule
@testable import Lithe

@Suite("Unified context menus")
@MainActor
struct ContextMenuCoverageTests {
    @Test
    func filterPopoverAnchorLeavesMouseEventsToItsButton() {
        let button = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        let anchor = GitLogPopoverAnchorView(frame: button.bounds)
        button.addSubview(anchor)
        // The overlay is only an anchor; swallowing hit tests broke both the
        // filter label's hover and the button's click before a popup opened.
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 50, y: 15), NSPoint(x: 99, y: 29)] {
            #expect(anchor.hitTest(point) == nil)
            #expect(button.hitTest(point) === button)
        }
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func searchableFilterContentCannotCoverSharedRoundedCorners(scheme: ColorScheme) throws {
        let menus: [AnyView] = [
            AnyView(GitLogBranchFilterPopover(
                menu: GitLogFilterList.branchMenu(references: []),
                querySections: { GitLogFilterList.branchSections(references: [], query: $0) },
                isItemSelected: { _ in false }, onSelect: { _ in }
            )),
            AnyView(GitLogFilterPopover(
                sectionsForQuery: { GitLogFilterList.authorSections(authors: [], query: $0) },
                searchPlaceholder: "Search users", emptyText: "No matching users",
                isItemSelected: { _ in false }, onSelect: { _ in }
            ))
        ]
        for menu in menus {
            let renderer = ImageRenderer(content: menu.environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            // The search strip used to paint an opaque rectangle over the shared corner.
            for x in [0, bitmap.pixelsWide - 1] {
                for y in [0, bitmap.pixelsHigh - 1] {
                    #expect(try #require(bitmap.colorAt(x: x, y: y)).alphaComponent < 0.05)
                }
            }
            #expect(try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 12)).alphaComponent > 0.95)
        }
    }

    @Test
    func anchoredActionAndSearchableDropdownsShareTopLeft() throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame
        for point in [NSPoint(x: screen.midX, y: floor(screen.midY)),
                      NSPoint(x: screen.maxX - 10, y: screen.minY + 10)] {
            var dismissals = 0
            presenter.show(items: [.action("Any Time", systemImage: "checkmark") {}],
                           at: point, appearance: NSAppearance(named: .darkAqua),
                           locale: Locale(identifier: "en"), anchored: true) { dismissals += 1 }
            let window = try #require(NSApp.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel")
            })
            let actionFrame = window.frame
            #expect(window.animationBehavior == .none)
            #expect(screen.contains(actionFrame))
            if point.x == screen.midX {
                #expect(actionFrame.minX == point.x)
                #expect(actionFrame.maxY == point.y)
            }
            try sendKey(53, to: window)
            #expect(dismissals == 1)
            let controller = LitheDropdownHostingController(rootView: AnyView(
                Text("Search branches").frame(width: actionFrame.width, height: actionFrame.height)
                    .litheContextMenuSurface()
            ))
            presenter.show(contentController: controller, at: point,
                           appearance: NSAppearance(named: .darkAqua)) { dismissals += 1 }
            let searchableWindow = try #require(controller.view.window)
            #expect(searchableWindow.frame == actionFrame)
            #expect(searchableWindow.animationBehavior == .none)
            presenter.dismiss()
            #expect(dismissals == 2)
        }
    }

    @Test
    func searchableDropdownUsesSharedWindowAndDismissal() throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame
        let controller = LitheDropdownHostingController(rootView: AnyView(
            Text("Filter").frame(width: 300, height: 120).litheContextMenuSurface()
        ))
        var dismissals = 0
        presenter.show(contentController: controller,
                       at: NSPoint(x: screen.midX, y: screen.midY),
                       appearance: NSAppearance(named: .darkAqua)) { dismissals += 1 }
        let window = try #require(controller.view.window)
        #expect(window.styleMask.contains(.borderless))
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.frame.width == 300)
        #expect(window.frame.height == 120)
        #expect(screen.contains(window.frame))
        // Search/group changes must resize the existing host rather than replace it.
        controller.rootView = AnyView(Text("Flyout").frame(width: 560, height: 200).litheContextMenuSurface())
        controller.view.layoutSubtreeIfNeeded()
        presenter.resize(contentController: controller)
        #expect(controller.view.window === window)
        #expect(window.frame.width == 560)
        #expect(window.frame.height == 200)
        try sendKey(53, to: window)
        #expect(!window.isVisible)
        #expect(dismissals == 1)
        presenter.dismiss()
        #expect(dismissals == 1)
    }

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
            onReset: { commit, mode in received.append("reset:\(mode.rawValue):\(commit.hash)") },
            onCreateTag: { received.append("tag:\($0.hash)") }
        ).contextMenuItems(for: commit)
        for title in ["New Tag…", "Cherry-pick Commit…", "Revert Commit…"] {
            try #require(menu.first { $0.title == title }).action()
        }
        let resetMenu = try #require(menu.first { $0.title == "Reset Current Branch to Here…" })
        guard case .submenu(let resetItems) = resetMenu.kind else {
            Issue.record("Reset should offer soft, mixed, and hard as a submenu")
            return
        }
        try #require(resetItems.first { $0.title == "Mixed Reset (Keep Changes Unstaged)" }).action()
        try #require(resetItems.first { $0.title == "Hard Reset (Discard Changes)" }).action()
        #expect(received == [
            "tag:abcdef123456", "cherry:abcdef123456", "revert:abcdef123456",
            "reset:mixed:abcdef123456", "reset:hard:abcdef123456"
        ])
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

    @Test(arguments: [false, true])
    func projectAndActionDropdownsRenderTheSameChrome(isDark: Bool) throws {
        // Capture the real panel: sharing tokens alone did not prevent the old
        // action-menu branch from rendering a different background and border.
        let menus: [[LitheContextMenuItem]] = [
            [.action("Project") {}, .action("Dependencies") {}],
            [.action("Fetch Options…") {},
             .action("Show Worktree Repositories", systemImage: "checkmark") {}]
        ]
        for items in menus {
            let presenter = LitheContextMenuPresenter()
            defer { presenter.dismiss() }
            presenter.show(items: items, at: NSPoint(x: 200, y: 300),
                           appearance: NSAppearance(named: isDark ? .darkAqua : .aqua),
                           locale: Locale(identifier: "en"))
            let window = try #require(NSApp.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel")
            })
            #expect(window.frame.height == 60)
            let host = try #require(window.contentView)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let y = bitmap.pixelsHigh / 2
            let probes: [(Int, UInt32)] = [
                (Int(3 * scale), isDark ? 0x2B2D30 : 0xFFFFFF),
                (0, isDark ? 0x4C4F56 : 0xE9EAEE)
            ]
            for (x, expected) in probes {
                let pixel = try #require(bitmap.colorAt(x: x, y: y))
                // AppKit caches in the display profile, while colorAt returns
                // generically tagged channels. Restore the bitmap's profile.
                let color = try #require(NSColor(colorSpace: bitmap.colorSpace,
                    components: [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent],
                    count: 4).usingColorSpace(.sRGB))
                #expect(abs(color.redComponent - CGFloat((expected >> 16) & 255) / 255) < 0.01)
                #expect(abs(color.greenComponent - CGFloat((expected >> 8) & 255) / 255) < 0.01)
                #expect(abs(color.blueComponent - CGFloat(expected & 255) / 255) < 0.01)
            }
        }
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
