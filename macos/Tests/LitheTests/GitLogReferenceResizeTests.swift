import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheGitModule

@MainActor
@Suite("Git Log reference resize integration", .serialized)
struct GitLogReferenceResizeTests {
    private final class DockState: ObservableObject {
        @Published var isVisible = true
    }

    private struct Dock<Content: View>: View {
        @ObservedObject var state: DockState
        let content: Content
        var body: some View {
            if state.isVisible { content } else { Color.clear }
        }
    }

    @Test
    func retainedHostsAreWindowOwnedAndSeparatedByTool() {
        weak var graph: NSView?
        weak var terminal: NSView?
        autoreleasepool {
            let store = WorkbenchToolContentStore()
            let graphSlot = WorkbenchToolContentStore.Slot()
            let terminalSlot = WorkbenchToolContentStore.Slot()
            store.show(.gitLog, in: graphSlot, identity: 0) { AnyView(EmptyView()) }
            store.show(.terminal, in: terminalSlot, identity: 0) { AnyView(EmptyView()) }
            graph = store.entries[.gitLog]?.host
            terminal = store.entries[.terminal]?.host
            #expect(graph != nil && terminal != nil)
            #expect(graph !== terminal)
            store.detach(graphSlot)
            #expect(store.entries[.gitLog]?.host === graph)
            #expect(store.entries[.terminal]?.host === terminal)
        }
        #expect(graph == nil, "Closing the workbench must release retained Git Log controls")
        #expect(terminal == nil, "Closing the workbench must release retained terminal controls")
    }

    @Test(arguments: [true, false])
    func retainedHostsPreserveOuterDividerHitArea(horizontal: Bool) async throws {
        let store = WorkbenchToolContentStore()
        var committed: [CGFloat] = []
        let host = NSHostingView(rootView: LitheSplitPaneView(
            axis: horizontal ? .horizontal : .vertical, placement: .leading,
            defaultSize: 240, minimum: 100, maximum: 400, onCommit: { committed.append($0) },
            sized: { RetainedWorkbenchToolContent(store: store, tool: .gitLog, content: Color.red) },
            flexible: { RetainedWorkbenchToolContent(store: store, tool: .terminal, content: Color.blue) })
            .overlay { WorkbenchToolContentSurface(store: store) }
            .padding(.leading, 20).padding(.top, 30))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let handle = try #require(descendants(host).compactMap { $0 as? SplitHandleInteractionView }.first)
        let hosts = store.entries.mapValues { ObjectIdentifier($0.host) }
        for offset: CGFloat in [0, -4, 4] {
            let center = NSPoint(x: handle.bounds.midX, y: handle.bounds.midY)
            let origin = handle.convert(NSPoint(x: center.x + (horizontal ? offset : 0),
                                               y: center.y + (horizontal ? 0 : offset)), to: nil)
            // hitTest takes the parent's coordinates, not the flipped host's.
            #expect(host.hitTest(host.superview?.convert(origin, from: nil) ?? origin) === handle,
                    "Both extensions of the 10pt hit surface must beat the retained hosts")
            let previousCount = committed.count
            let previousSize = committed.last ?? 240
            for (type, delta) in [(NSEvent.EventType.leftMouseDown, CGFloat(0)), (.leftMouseDragged, 20), (.leftMouseUp, 20)] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: origin.x + (horizontal ? delta : 0), y: origin.y - (horizontal ? 0 : delta)),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
            }
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            #expect(committed.count == previousCount + 1, "Window-dispatched drag must commit exactly once")
            #expect(committed.last == previousSize + 20)
            #expect(store.entries.mapValues { ObjectIdentifier($0.host) } == hosts)
        }
        for entry in store.entries.values {
            let point = entry.host.convert(NSPoint(x: entry.host.bounds.midX, y: entry.host.bounds.midY), to: host.superview)
            #expect(host.hitTest(point)?.isDescendant(of: entry.host) == true,
                    "Panel interiors must remain interactive")
        }
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func loadedBranchesRemainLazyDuringHeightChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-reference-resize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Real Git fixture setup needs a bounded integration budget on loaded CI hosts.
        // Keep the shared process helper's shorter default for other tests.
        func git(_ arguments: [String]) async throws -> String {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments, currentDirectoryURL: root, timeout: .seconds(15))
            try #require(result.terminationStatus == 0, "\(String(decoding: result.output, as: UTF8.self))")
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["-c", "user.name=Lithe Test", "-c", "user.email=test@example.invalid",
                          "commit", "-q", "--allow-empty", "-m", "Initial"])
        let hash = try await git(["rev-parse", "HEAD"])
        let count = 1_000
        let refs = (0..<count).map { "\(hash) refs/heads/branch-\(String(format: "%04d", $0))" }.joined(separator: "\n")
        try Data((refs + "\n").utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        let suite = "lithe-reference-resize-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true },
                          notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        try #require(feature.gitReferences.count == count + 1)
        let cache = GitLogPresentationCache()
        let contentStore = WorkbenchToolContentStore()
        func content() -> some View {
            RetainedWorkbenchToolContent(store: contentStore, tool: .gitLog, content:
            GitLogView(feature: feature, workbench: model.workbenchFeature,
                background: model.workbenchBackgroundFeature, projectName: "Resize fixture",
                navigation: GitLogNavigation(compareWithWorkingTree: { _ in }, compareReferences: { _, _ in }, openCommitDiff: { _ in }),
                worktreeActions: GitWorktreeActions(openProject: { _ in }, reveal: { _ in }, copyPath: { _ in }, chooseParentDirectory: { nil }),
                presentationCache: cache)
                .environmentObject(settings))
        }
        let dock = DockState()
        let host = NSHostingView(rootView: Dock(state: dock, content: LitheSplitPaneView(axis: .vertical, placement: .trailing,
            defaultSize: 350, minimum: 100, maximum: 550, sized: { content() }, flexible: { Color.clear }))
            .overlay { WorkbenchToolContentSurface(store: contentStore) })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func menus() -> [NSView] {
            descendants(host).filter { String(describing: type(of: $0)) == "LitheRightClickCaptureView" }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while menus().isEmpty && clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        try #require(!menus().isEmpty, "Git Log did not mount branch rows before the deadline")
        let graphIdentity = GitLogPresentationCache.Identity(historyVersion: feature.gitCommitsVersion,
            repositoryVersion: feature.gitGraphRepositoryVersion, referencesVersion: feature.gitReferencesVersion,
            filterVersion: 0, filtering: false, showLongEdges: false, highlightsCurrentBranch: false)
        let graphDeadline = clock.now.advanced(by: .seconds(3))
        while cache.value(for: graphIdentity)?.rows.isEmpty != false && clock.now < graphDeadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        try #require(cache.value(for: graphIdentity)?.rows.isEmpty == false,
                     "Git Log did not prepare its presentation before the deadline")
        let before = menus().count
        let mountedGraph = try #require(descendants(host).compactMap { $0 as? GitGraphScrollDocumentView }.first)
        let handle = try #require(descendants(host).compactMap { $0 as? SplitHandleInteractionView }
            .first { $0.axis == .vertical })
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x, y: origin.y + offset),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        window.sendEvent(try event(.leftMouseDown))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        var durations: [Duration] = []
        for offset: CGFloat in [150, -150, 100, -50, 200, 0] {
            let start = clock.now
            window.sendEvent(try event(.leftMouseDragged, offset: offset))
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            durations.append(start.duration(to: clock.now))
            let entry = try #require(contentStore.entries[.gitLog])
            let slot = try #require(entry.slot)
            #expect(descendants(host).compactMap { $0 as? GitGraphScrollDocumentView }.first === mountedGraph,
                    "Dragging the dock must not recreate the commit document view")
            #expect(entry.host.frame == slot.convert(slot.bounds, to: contentStore.surface),
                    "Native content must follow the actual dock bounds during resizing")
        }
        window.sendEvent(try event(.leftMouseUp))
        host.layoutSubtreeIfNeeded()
        print("GIT_LOG_RESIZE refs=\(count) mounted=\(before)->\(menus().count) layouts=\(durations)")
        #expect(menus().count < 100, "Offscreen branches must not mount their native row controls")
        let originalGraph = try #require(descendants(host).compactMap { $0 as? GitGraphScrollDocumentView }.first)
        let originalScroll = try #require(originalGraph.enclosingScrollView)
        // A Git Log/Terminal switch reuses the same representable slot.
        let gitEntry = try #require(contentStore.entries[.gitLog])
        let sharedSlot = try #require(gitEntry.slot)
        contentStore.show(.terminal, in: sharedSlot, identity: 0) { AnyView(Text("Terminal fixture")) }
        #expect(gitEntry.slot == nil)
        #expect(gitEntry.host.isHidden)
        #expect(contentStore.entries[.terminal]?.host.isHidden == false)
        contentStore.show(.gitLog, in: sharedSlot, identity: gitEntry.identity) {
            Issue.record("Switching tools must reuse the existing content")
            return AnyView(EmptyView())
        }
        #expect(contentStore.entries[.terminal]?.slot == nil)
        #expect(contentStore.entries[.terminal]?.host.isHidden == true)
        #expect(!gitEntry.host.isHidden)
        // Hide only the dock, keeping the workbench's hosting tree alive.
        // Replacing the whole window host would instead represent a new workbench.
        dock.isVisible = false
        host.layoutSubtreeIfNeeded()
        #expect(originalGraph.isHiddenOrHasHiddenAncestor)
        #expect(contentStore.surface.accessibilityChildren()?.isEmpty == true,
                "Hidden retained tools must not expose their controls to accessibility")
        #expect(originalGraph.window === window, "Hidden controls stay mounted in the workbench")
        let reopenStarted = clock.now
        dock.isVisible = true
        let reopenDeadline = clock.now.advanced(by: .seconds(3))
        while originalGraph.isHiddenOrHasHiddenAncestor && clock.now < reopenDeadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let graph = try #require(descendants(host).compactMap { $0 as? GitGraphScrollDocumentView }.first)
        #expect(contentStore.surface.accessibilityChildren()?.isEmpty == false)
        #expect(!graph.isHiddenOrHasHiddenAncestor, "Reopened controls must actually be visible")
        #expect(graph.bounds.width > 0 && graph.bounds.height > 0)
        #expect(graph === originalGraph, "Reopening must reuse the actual commit document view")
        #expect(graph.enclosingScrollView === originalScroll, "Reopening must reuse the actual scroll view")
        #expect(graph.accessibilityChildren()?.isEmpty == false,
                "Retained commits must be present without waiting for appearance tasks")
        #expect(descendants(host).contains { String(describing: type(of: $0)) == "LitheRightClickCaptureView" },
                "Retained branch rows must be present in the first layout")
        print("GIT_LOG_REOPEN refs=\(count) restore=\(reopenStarted.duration(to: clock.now))")
    }
}
