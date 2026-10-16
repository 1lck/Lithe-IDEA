import AppKit
import SwiftUI
import Testing
import LitheGitModule
@testable import Lithe

@MainActor
@Suite("Worktree shared appearance", .serialized)
struct GitWorktreeAppearanceTests {
    @Test(arguments: [false, true])
    func nativeSelectionUsesSharedFocusColors(dark: Bool) throws {
        let item = item("main")
        let view = GitWorktreeListNSView(frame: CGRect(x: 0, y: 0, width: 286, height: 80))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        for focused in [true, false, true] {
            #expect(view.update(items: [item], selectedWorktreeID: item.id, isFocused: focused, onSelect: { _ in }))
            let bitmap = try nativeSRGBCapture(view)
            let pixel = try nativeSRGBPixel(bitmap, x: 16, y: 80)
            let expected: UInt32 = dark
                ? (focused ? 0x2A4371 : 0x33353B)
                : (focused ? 0xD0DFFE : 0xE9EAEE)
            #expect(abs(pixel.redComponent * 255 - CGFloat((expected >> 16) & 255)) <= 2)
            #expect(abs(pixel.greenComponent * 255 - CGFloat((expected >> 8) & 255)) <= 2)
            #expect(abs(pixel.blueComponent * 255 - CGFloat(expected & 255)) <= 2)
        }
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
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
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
            window.setContentSize(CGSize(width: width, height: 620))
            host.layoutSubtreeIfNeeded()
            #expect(list() === original)
            #expect(original.bounds.width >= 286)
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
