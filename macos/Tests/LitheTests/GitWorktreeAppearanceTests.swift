import AppKit
import SwiftUI
import Testing
import LitheGitModule
@testable import Lithe

@MainActor
@Suite("Worktree shared appearance", .serialized)
struct GitWorktreeAppearanceTests {
    @Test(arguments: [false, true])
    func changelistHeadersSeparateExpansionStagingAndFileNavigation(dark: Bool) throws {
        let changes = (0..<4).map {
            GitChange(repositoryRoot: URL(fileURLWithPath: "/linked"), path: "file-\($0).swift",
                originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        }
        let snapshot = GitWorktreeRowsSnapshot(identity: .changes(inspectionVersion: 1), rows:
            [.changelist(id: "list", name: "Local", changes: changes, expanded: true)] + changes.map { .change($0) },
            stagedOverrides: [changes[0].id: true])
        let scroll = GitWorktreeRowsScrollView.makeScrollView(snapshot: snapshot)
        let window = TreeListAppearanceWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        let view = try #require(scroll.documentView as? GitWorktreeRowsNSView)
        var selected: Set<String> = [], expanded: [String] = [], staged: [[GitChange]] = [], opened: [GitChange] = []
        view.configureInteraction(GitWorktreeChangeInteraction(selectedIDs: [], isEnabled: true,
            onSelection: { selected = $0 }, onToggle: { _ in }, onOpen: { opened.append($0) }, menuItems: { _ in [] },
            onToggleList: { staged.append($0) }, onExpandList: { expanded.append($0) }))
        let rows = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let header = try #require(rows.first)
        let checkbox = try #require(header.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(checkbox.accessibilityValue() as? Int == NSControl.StateValue.mixed.rawValue)
        #expect(header.accessibilityPerformPress())
        #expect(expanded == ["list"] && staged.isEmpty && selected.isEmpty && opened.isEmpty)
        #expect(checkbox.accessibilityPerformPress())
        #expect(staged == [changes] && selected.isEmpty && opened.isEmpty)
        for code: UInt16 in [125, 119] {
            view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
        }
        #expect(selected == [changes.last!.id] && opened.isEmpty)
        #expect(scroll.contentView.bounds.maxY >= CGFloat(snapshot.rows.count) * GitWorktreeRowsView.rowHeight,
            "Keyboard scrolling includes ChangeList header offsets")
        let collapsed = GitWorktreeRowsSnapshot(identity: snapshot.identity,
            rows: [.changelist(id: "list", name: "Local", changes: changes, expanded: false)])
        GitWorktreeRowsScrollView.updateScrollView(scroll, snapshot: collapsed)
        #expect(view.accessibilityChildren()?.count == 1)
        _ = try nativeSRGBCapture(view)
    }

    @Test(arguments: [false, true])
    func changesSeparateSelectionStagingDiffAndContextTargets(dark: Bool) throws {
        let changes = (0..<4).map {
            GitChange(repositoryRoot: URL(fileURLWithPath: "/linked"), path: "file-\($0).swift",
                      originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        }
        let snapshot = GitWorktreeRowsSnapshot(identity: .changes(inspectionVersion: 1), rows: changes.map { .change($0) })
        let scroll = GitWorktreeRowsScrollView.makeScrollView(snapshot: snapshot)
        let window = TreeListAppearanceWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = scroll
        defer { LitheContextMenuPresenter.shared.dismiss(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        let view = try #require(scroll.documentView as? GitWorktreeRowsNSView)
        var selection = GitChangeSelection()
        var toggles: [String] = [], opens: [String] = [], menuTargets: [String] = []
        func configure(enabled: Bool) {
            view.configureInteraction(GitWorktreeChangeInteraction(selectedIDs: selection.ids, isEnabled: enabled,
                onSelection: { selection.replace(with: $0) }, onToggle: { toggles.append($0.id) },
                onOpen: { opens.append($0.id) }, menuItems: { change in
                    menuTargets = selection.actionTargets(in: changes, clicked: change).map(\.id)
                    return [.action("Show Diff") {}]
                }))
        }
        func click(_ index: Int, checkbox: Bool = false, flags: NSEvent.ModifierFlags = [], right: Bool = false) throws {
            let point = CGPoint(x: checkbox ? GitWorktreeRowsNSView.checkboxRect(in: view.bounds).midX : 100,
                                y: (CGFloat(index) + 0.5) * GitWorktreeRowsView.rowHeight)
            let event = try #require(NSEvent.mouseEvent(with: right ? .rightMouseDown : .leftMouseDown,
                location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if right { _ = view.menu(for: event) } else { view.mouseDown(with: event) }
        }
        func key(_ code: UInt16) throws {
            view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
        }
        configure(enabled: true)
        try click(0, checkbox: true)
        #expect(toggles == [changes[0].id] && selection.ids.isEmpty && opens.isEmpty)
        try click(0)
        try click(1, flags: .command)
        #expect(selection.ids == Set(changes.prefix(2).map(\.id)))
        try click(3, flags: .shift)
        #expect(selection.ids == Set(changes.suffix(3).map(\.id)))
        #expect(opens == [changes[0].id], "Range and additive selection must not open a Diff")
        try key(49)
        #expect(toggles.last == changes[3].id)
        try key(36)
        #expect(opens.last == changes[3].id)
        try click(1, right: true)
        #expect(menuTargets == changes.suffix(3).map(\.id))
        LitheContextMenuPresenter.shared.dismiss()
        try click(0)
        try click(2, right: true)
        #expect(menuTargets == [changes[2].id])
        #expect(selection.ids == [changes[2].id])
        LitheContextMenuPresenter.shared.dismiss()
        configure(enabled: false)
        let toggleCount = toggles.count
        try click(0, checkbox: true)
        try key(49)
        let rows = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let checkbox = try #require(rows[0].accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(!checkbox.isAccessibilityEnabled())
        #expect(toggles.count == toggleCount)
        for width: CGFloat in [300, 850, 600] {
            scroll.setFrameSize(CGSize(width: width, height: 160))
            scroll.layoutSubtreeIfNeeded()
            #expect(view.bounds.width == scroll.contentView.bounds.width)
            #expect(selection.ids == [changes[2].id])
            _ = try nativeSRGBCapture(view)
        }
        view.selectAll(nil)
        #expect(selection.ids == Set(changes.map(\.id)))
    }

    @Test(arguments: [false, true])
    func changesPageMountsSharedActionsAndOpensSelectedWorktreeDiff(dark: Bool) async throws {
        let worktree = item("main").worktree
        let change = GitChange(repositoryRoot: worktree.url, path: "Sources/Example.swift", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let snapshot = GitSnapshot(repositoryRoot: worktree.url, branch: "main", changes: [change])
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())),
            snapshotProvider: { _ in snapshot }, stashesProvider: { _ in [] }, operationStateProvider: { _ in nil },
            worktreesProvider: { _ in [worktree] }, repositoryRootsProvider: { _ in [worktree.url] })
        feature.configure(workspaceURLProvider: { worktree.url }, isGitLogVisibleProvider: { false },
                          notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.refreshWorktrees()
        await feature.inspectWorktree(worktree)
        var opened: [GitChange] = []
        let actions = GitWorktreeActions(openProject: { _ in }, reveal: { _ in }, copyPath: { _ in },
            chooseParentDirectory: { nil }, showChange: { opened.append($0) })
        let scoped = feature.commitFeature(for: worktree)
        let draft = CommitDraftFeatureModel()
        draft.message = "Keep this checkout's draft"
        let workflow = CommitWorkflowCoordinator(draft: draft, activateGit: { scoped },
            workspaceGeneration: { 0 }, generate: { _ in "Generated" }, notify: { _ in })
        let session = WorktreeCommitSession(feature: scoped, draft: draft, workflow: workflow)
        let content = GitWorktreeChangesView(feature: feature, worktree: worktree,
            snapshot: GitWorktreeRowsSnapshot(identity: .changes(inspectionVersion: 1), rows: [.change(change)]), actions: actions,
            commitSession: session)
            .background(LitheTheme.editor)
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale(identifier: "en"))
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        let window = TreeListAppearanceWindow(contentRect: CGRect(x: 0, y: 0, width: 850, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        _ = try await AgentNativeControlTestSupport.frame(of: "worktree-changes-Refresh changes", in: host)
        // Nothing is selected, yet the toolbar is not a row of dead buttons: staging and the diff
        // work on the files as a whole, and only the irreversible discard waits for a selection.
        #expect(try await AgentNativeControlTestSupport.isEnabled("worktree-changes-Stage all files", in: host))
        #expect(try await AgentNativeControlTestSupport.isEnabled("worktree-changes-Show Diff", in: host))
        #expect(try await !AgentNativeControlTestSupport.isEnabled("worktree-changes-Discard selected change", in: host))
        #expect(try await !AgentNativeControlTestSupport.isEnabled("git-commit-submit", in: host))
        let document = try #require(descendants(host).compactMap { $0 as? GitWorktreeRowsNSView }.first)
        let point = document.convert(CGPoint(x: 100, y: GitWorktreeRowsView.rowHeight * 1.5), to: nil)
        document.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(opened == [change] && opened.first?.repositoryRoot == worktree.url)
        #expect(try await AgentNativeControlTestSupport.isEnabled("worktree-changes-Discard selected change", in: host))
        var previousDocument = document
        var previousAxis = LitheSplitAxis.horizontal
        for width: CGFloat in [850, 700, 320, 600, 850] {
            window.setContentSize(CGSize(width: width, height: 300))
            host.layoutSubtreeIfNeeded()
            for title in ["Stage all files", "Discard selected change", "Show Diff"] {
                let frame = try await AgentNativeControlTestSupport.frame(of: "worktree-changes-" + title, in: host)
                #expect(host.bounds.contains(frame))
            }
            let currentDocument = try #require(descendants(host).compactMap { $0 as? GitWorktreeRowsNSView }.first)
            let axis = GitWorktreeChangesLayout(size: CGSize(width: width, height: 300)).axis
            if axis == previousAxis { #expect(currentDocument === previousDocument) }
            let accessibleRows = try #require(currentDocument.accessibilityChildren() as? [NSAccessibilityElement])
            #expect(accessibleRows.last?.isAccessibilitySelected() == true)
            previousDocument = currentDocument
            previousAxis = axis
            let editor = try #require(descendants(host).compactMap { $0 as? CommitMessageTextView }.first)
            #expect(editor.string == draft.message)
            let editorFrame = host.convert(editor.bounds, from: editor)
            let scroll = try #require(currentDocument.enclosingScrollView)
            let filesFrame = host.convert(scroll.bounds, from: scroll)
            #expect(filesFrame.height >= 2 * GitWorktreeRowsView.rowHeight,
                "Narrow layouts must leave room for a ChangeList header and file, not just the toolbars")
            if width >= 620 { #expect(editorFrame.minX > filesFrame.maxX) }
            else { #expect(editorFrame.midY != filesFrame.midY) }
            let commitFrame = try await AgentNativeControlTestSupport.frame(of: "git-commit-submit", in: host)
            #expect(host.bounds.contains(commitFrame))
            if let directory = ProcessInfo.processInfo.environment["LITHE_WORKTREE_CAPTURE_DIR"] {
                let bitmap = try nativeSRGBCapture(host)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent("changes-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
    }

    @Test
    func changesLayoutClampsBothPanesAndSessionsKeepSeparateDrafts() {
        for size in [CGSize(width: 0, height: 0), CGSize(width: 320, height: 120),
                     CGSize(width: 600, height: 300), CGSize(width: 850, height: 300)] {
            let layout = GitWorktreeChangesLayout(size: size)
            let available = max(0, (layout.axis == .horizontal ? size.width : size.height) - SplitHandleView.thickness)
            #expect(layout.commitMinimum >= 0 && layout.listMinimum >= 0)
            #expect(layout.commitSize >= layout.commitMinimum && layout.commitSize <= layout.commitMaximum)
            #expect(layout.commitSize + layout.listMinimum <= available)
        }
        let host = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        defer { host.reset() }
        let sessions = WorktreeCommitSessions()
        func session(_ name: String, generation: Int = 1) -> WorktreeCommitSession {
            let feature = host.commitFeature(for: item(name).worktree)
            return sessions.session(for: feature, generation: generation) {
                let draft = CommitDraftFeatureModel()
                return WorktreeCommitSession(feature: feature, draft: draft,
                    workflow: CommitWorkflowCoordinator(draft: draft, activateGit: { feature },
                        workspaceGeneration: { generation }, generate: { _ in "Generated" }, notify: { _ in }))
            }
        }
        let first = session("first")
        first.draft.message = "First checkout"
        let second = session("second")
        second.draft.message = "Second checkout"
        #expect(session("first") === first && session("second") === second)
        #expect(first.draft.message == "First checkout")
        #expect(session("first", generation: 2).draft.message.isEmpty)
    }

    @Test(arguments: [false, true])
    func nativeSelectionUsesSharedFocusColors(dark: Bool) throws {
        let item = item("main")
        let view = GitWorktreeListNSView(frame: CGRect(x: 0, y: 0, width: 286, height: 80))
        let window = TreeListAppearanceWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.update(items: [item], selectedWorktreeID: item.id, onSelect: { _ in })
        window.makeKeyAndOrderFront(nil)
        for focused in [true, false, true] {
            if focused { window.makeFirstResponder(view) } else { window.makeFirstResponder(nil) }
            #expect((window.isKeyWindow && window.firstResponder === view) == focused)
            let bitmap = try nativeSRGBCapture(view)
            let pixel = try nativeSRGBPixel(bitmap, x: 25, y: 80)
            let expected: UInt32 = dark
                ? (focused ? 0x2A4371 : 0x33353B)
                : (focused ? 0xD0DFFE : 0xE9EAEE)
            #expect(abs(pixel.redComponent * 255 - CGFloat((expected >> 16) & 255)) <= 2)
            #expect(abs(pixel.greenComponent * 255 - CGFloat((expected >> 8) & 255)) <= 2)
            #expect(abs(pixel.blueComponent * 255 - CGFloat(expected & 255)) <= 2)
        }
    }

    @Test
    func requestedStagedStateReachesTheRowWhileClicksAreStillRefused() throws {
        let change = GitChange(repositoryRoot: URL(fileURLWithPath: "/linked"), path: "file.swift",
                               originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        var snapshot = GitWorktreeRowsSnapshot(identity: .changes(inspectionVersion: 1), rows: [.change(change)])
        #expect(!snapshot.isStaged(change))
        snapshot.stagedOverrides = [change.id: true]
        #expect(snapshot.isStaged(change))
        let view = GitWorktreeRowsNSView(frame: CGRect(x: 0, y: 0, width: 600, height: 60))
        view.update(snapshot: snapshot, rowHeight: GitWorktreeRowsView.rowHeight)
        var toggles = 0
        view.configureInteraction(GitWorktreeChangeInteraction(selectedIDs: [], isEnabled: false, paintsAsEnabled: true,
            onSelection: { _ in }, onToggle: { _ in toggles += 1 }, onOpen: { _ in }, menuItems: { _ in [] }))
        let rows = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let checkbox = try #require(rows[0].accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(checkbox.accessibilityValue() as? Int == 1)
        // A toggle still being applied refuses the next click; it only stays painted as usable.
        #expect(!checkbox.isAccessibilityEnabled())
        let point = view.convert(CGPoint(x: GitWorktreeRowsNSView.checkboxRect(in: CGRect(x: 0, y: 0, width: 600,
            height: GitWorktreeRowsView.rowHeight)).midX, y: GitWorktreeRowsView.rowHeight / 2), to: nil)
        view.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(toggles == 0)
    }

    @Test(arguments: [(false, false), (false, true), (true, false)])
    func historyViewportFillsAvailableHeightWithoutAnIdleFooter(isLoading: Bool, failed: Bool) async throws {
        var loads = 0
        let snapshot = GitWorktreeRowsSnapshot(identity: .history(inspectionVersion: 1, query: ""),
            rows: (0..<100).map { .commit(subject: "Commit \($0)", author: "Author", date: "2026-10-29") })
        let host = NSHostingView(rootView: GitWorktreeHistoryList(snapshot: snapshot, contextID: "worktree",
            canLoadMore: true, isLoadingMore: isLoading, loadMoreFailed: failed,
            onLoadMore: { loads += 1 }, onRetry: { loads += 1 })
            .environment(\.locale, Locale(identifier: "en")))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !descendants(host).contains(where: { $0 is GitWorktreeRowsScrollNSView }) && clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? GitWorktreeRowsScrollNSView }.first)
        for height: CGFloat in [120, 300, 600] {
            window.setContentSize(CGSize(width: 600, height: height))
            host.layoutSubtreeIfNeeded()
            let frame = host.convert(scroll.bounds, from: scroll)
            #expect(abs(frame.minY - host.bounds.minY) < 0.5)
            #expect(abs(frame.maxY - host.bounds.maxY) < 0.5, "Paging feedback must not reserve a footer band")
        }
        if failed {
            let frame = try await AgentNativeControlTestSupport.frame(of: "worktree-history-retry", in: host)
            #expect(host.bounds.contains(frame))
        }
        #expect(loads == 0)
    }

    @Test
    func keyboardSelectionStopsAtListBounds() {
        let items = [item("main"), item("feature")]
        let view = GitWorktreeListNSView(frame: CGRect(x: 0, y: 0, width: 286, height: 160))
        var selections: [String] = []
        view.update(items: items, selectedWorktreeID: nil, onSelect: { selections.append($0) })
        view.moveDown(nil)
        view.moveDown(nil)
        view.moveDown(nil)
        view.moveUp(nil)
        view.moveUp(nil)
        #expect(selections == [items[0].id, items[1].id, items[0].id])
    }

    @Test(arguments: [false, true])
    func pathExpansionUsesAvailableWidthAndClearsOutsideThePath(dark: Bool) throws {
        let item = item(String(repeating: "long-feature-", count: 8))
        let view = GitWorktreeListNSView(frame: CGRect(x: 0, y: 0, width: 600, height: 160))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.update(items: [item], selectedWorktreeID: item.id, onSelect: { _ in })
        let content = GitWorktreeListNSView.contentRect(in: CGRect(x: 0, y: 4, width: 600, height: 72))
        let highlight = LitheTreeListAppearance.highlightRect(CGRect(x: 0, y: 4, width: 600, height: 72))
        #expect(content.minX - highlight.minX == LitheTheme.Tree.horizontalInset)
        #expect(highlight.maxX - content.maxX == LitheTheme.Tree.horizontalInset)
        func hover(_ point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
            view.mouseMoved(with: event)
        }
        try hover(CGPoint(x: content.minX + 10, y: content.minY + 28))
        let expansion = view.expansionFrame(withFrame: view.bounds)
        #expect(view.allowsExpansionToolTips)
        #expect(expansion.minX == content.minX)
        #expect(expansion.width > content.width)
        let fullWidth = ceil((item.worktree.path as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 12.5)]).width)
        #expect(expansion.width == fullWidth)
        // The entire path line can expand; the branch remains a separate row.
        try hover(CGPoint(x: content.maxX - 1, y: content.minY + 28))
        #expect(view.expansionFrame(withFrame: view.bounds).width == fullWidth)
        try hover(CGPoint(x: content.minX + 10, y: content.minY + 48))
        #expect(view.expansionFrame(withFrame: view.bounds).isEmpty)

        for width: CGFloat in [286, 600, fullWidth + 100, 400] {
            view.updateLayout(width: width)
            let row = CGRect(x: 0, y: GitWorktreeListScrollView.verticalInset, width: width, height: GitWorktreeListScrollView.rowHeight)
            let content = GitWorktreeListNSView.contentRect(in: row)
            let path = GitWorktreeListNSView.pathRect(in: content)
            #expect(path.width == content.width)
            try hover(CGPoint(x: path.midX, y: path.midY))
            #expect(view.expansionFrame(withFrame: view.bounds).isEmpty == (path.width >= fullWidth))
            _ = try nativeSRGBCapture(view)
        }
    }

    @Test
    func listHeightTracksRowCountAtTheSameWidth() throws {
        let items = (0..<20).map { item("branch-\($0)") }
        let scroll = GitWorktreeListScrollView.makeScrollView(
            items: [items[0]], selectedWorktreeID: nil, onSelect: { _ in })
        scroll.frame = CGRect(x: 0, y: 0, width: 286, height: 160)
        scroll.layoutSubtreeIfNeeded()
        let view = try #require(scroll.documentView as? GitWorktreeListNSView)
        let width = scroll.contentView.bounds.width
        view.updateLayout(width: width)
        let singleRowHeight = view.frame.height

        view.update(items: items, selectedWorktreeID: nil, onSelect: { _ in })
        #expect(view.updateLayout(width: width))
        #expect(view.frame.height > scroll.contentView.bounds.height)
        view.scrollToVisible(CGRect(x: 0, y: view.bounds.maxY - 1, width: 1, height: 1))
        #expect(scroll.contentView.bounds.maxY >= view.bounds.maxY - 1)
        #expect(!view.updateLayout(width: width))

        view.update(items: [items[0]], selectedWorktreeID: nil, onSelect: { _ in })
        #expect(view.updateLayout(width: width))
        #expect(view.frame.height == singleRowHeight)
        view.update(items: [], selectedWorktreeID: nil, onSelect: { _ in })
        #expect(view.updateLayout(width: width))
        #expect(view.frame.height == GitWorktreeListScrollView.verticalInset * 2)
    }

    @Test(arguments: [false, true])
    func historyScrollAutomaticallyAppendsWithoutMovingViewport(dark: Bool) async throws {
        func snapshot(_ count: Int) -> GitWorktreeRowsSnapshot {
            GitWorktreeRowsSnapshot(identity: .history(inspectionVersion: count, query: ""),
                rows: (0..<count).map { .commit(subject: "Commit \($0)", author: "Author", date: "2026-10-28") })
        }
        let scroll = GitWorktreeRowsScrollView.makeScrollView(snapshot: snapshot(50))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 850, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var requests = 0
        func update(_ count: Int, loading: Bool = false, failed: Bool = false, more: Bool = true,
                    context: String = "worktree") {
            GitWorktreeRowsScrollView.updateScrollView(scroll, snapshot: snapshot(count), contextID: context,
                canLoadMore: more, isLoadingMore: loading, loadMoreFailed: failed, onLoadMore: { requests += 1 })
            scroll.layoutSubtreeIfNeeded()
        }
        func settle() async {
            // Drain the native main-queue edge callback, not a wall-clock sleep.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        scroll.layoutSubtreeIfNeeded()
        let document = try #require(scroll.documentView as? GitWorktreeRowsNSView)
        update(50)
        await settle()
        #expect(requests == 0)
        let y = document.bounds.height - scroll.contentView.bounds.height - 100
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        #expect(requests == 1)
        document.scheduleAutomaticLoading()
        await settle()
        #expect(requests == 1, "Repeated edge notifications cannot request the same page")
        update(50, loading: true)
        await settle()
        #expect(requests == 1)
        update(100)
        await settle()
        #expect(document.bounds.height == 100 * GitWorktreeRowsView.rowHeight)
        #expect(abs(scroll.contentView.bounds.minY - y) < 1)
        #expect(requests == 1)
        #expect(scroll.documentView === document)
        for width: CGFloat in [600, 900, 850] {
            scroll.setFrameSize(CGSize(width: width, height: 300))
            scroll.needsLayout = true
            scroll.layoutSubtreeIfNeeded()
            #expect(document.bounds.width == scroll.contentView.bounds.width)
            #expect(abs(scroll.contentView.bounds.minY - y) < 1)
        }
        update(100, failed: true)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        #expect(requests == 1, "Errors must wait for an explicit retry")
        update(100, more: false)
        await settle()
        #expect(requests == 1, "Exhaustion stops automatic fetching")
        update(100, more: false, context: "worktree/search")
        #expect(scroll.contentView.bounds.minY == 0, "A new query is a new scroll context")
        update(2, context: "short-worktree")
        await settle()
        #expect(requests == 2, "Short content fills the viewport automatically")
        #expect(document.bounds.height == 2 * GitWorktreeRowsView.rowHeight)
        update(2, more: false)
        await settle()
        #expect(requests == 2)
    }

    @Test(arguments: [false, true])
    func pageRetainsNativeListAcrossPaneResizing(dark: Bool) async throws {
        MacBundledFontRegistry.registerFonts()
        let items = [item("main"), item("feature")]
        let root = items[0].worktree.url
        let snapshot = GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        let feature = GitFeatureModel(
            service: GitService(operations: RustGitOperations(core: RustCoreBridge())),
            snapshotProvider: { _ in snapshot }, stashesProvider: { _ in [] },
            operationStateProvider: { _ in nil }, worktreesProvider: { _ in items.map(\.worktree) },
            repositoryRootsProvider: { _ in [root] })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let suite = "worktree-appearance-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
        let background = WorkbenchBackgroundFeatureModel(settings: settings, platform: UnavailableWorkbenchBackgroundPlatform())
        let content = GitWorktreesView(feature: feature, background: background,
            actions: GitWorktreeActions(openProject: { _ in }, reveal: { _ in }, copyPath: { _ in }, chooseParentDirectory: { nil }))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "en"))
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func list() -> GitWorktreeListNSView? { descendants(host).compactMap { $0 as? GitWorktreeListNSView }.first }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while list() == nil && clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let original = try #require(list(), "Worktree projection did not mount before the deadline")
        for width: CGFloat in [1400, 1000, 760] {
            window.setContentSize(CGSize(width: width, height: 900))
            host.layoutSubtreeIfNeeded()
            #expect(list() === original)
            #expect(original.bounds.width >= 286)
            let open = try await AgentNativeControlTestSupport.frame(of: "worktree-action-Open in Current Window", in: host)
            let newWindow = try await AgentNativeControlTestSupport.frame(of: "worktree-action-Open in New Window", in: host)
            let finder = try await AgentNativeControlTestSupport.frame(of: "worktree-action-Show in Finder", in: host)
            let copy = try await AgentNativeControlTestSupport.frame(of: "worktree-action-Copy Path", in: host)
            // One flow in label order: a button that fits follows its neighbour, one that does not
            // wraps back to the left edge, so no row is padded to line up with another.
            let actions = [open, newWindow, finder, copy]
            for (previous, next) in zip(actions, actions.dropFirst()) {
                if abs(next.midY - previous.midY) < 0.5 {
                    #expect(abs(next.minX - previous.maxX - LitheTheme.ActionButton.spacing) < 0.5)
                } else {
                    #expect(abs(next.minX - open.minX) < 0.5)
                }
            }
            if width == 1400 {
                #expect(actions.allSatisfy { abs($0.midY - open.midY) < 0.5 }, "Wide windows keep every action on one row")
            }
            #expect(abs(open.height - LitheTheme.ActionButton.height) < 0.5)
            #expect(open.width > finder.width, "Actions keep their natural label widths, rather than equal grid cells")
            #expect([open, newWindow, finder, copy].allSatisfy { host.bounds.contains($0) })
            if let directory = ProcessInfo.processInfo.environment["LITHE_WORKTREE_CAPTURE_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent("worktrees-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
    }

    private func item(_ name: String) -> GitWorktreeListItem {
        GitWorktreeListItem(worktree: GitWorktree(
            path: "/test/worktrees/\(name)", head: "abcdef", branch: "refs/heads/\(name)",
            isCurrent: name == "main", isPrimary: name == "main", isBare: false, isDetached: false, isLocked: false,
            lockReason: nil, isPrunable: false, pruneReason: nil
        ), status: .available)
    }
}

@MainActor
private final class TreeListAppearanceWindow: NSWindow {
    // The isolated test host intentionally never becomes the desktop's key window.
    override var isKeyWindow: Bool { true }
}
