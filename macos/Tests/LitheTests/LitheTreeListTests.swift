import AppKit
import SwiftUI
import Testing

@testable import Lithe

@MainActor
@Suite("Complete shared tree/list", .serialized)
struct LitheTreeListTests {
    @Test func selectionPreservesRangeAnchorAndCommandUnion() {
        let rows = ["a", "b", "c", "d"]
        #expect(
            LitheTreeListSelection.select("d", in: rows, selected: ["a"], anchor: "b", extending: true, toggling: false)
                == ["b", "c", "d"])
        #expect(
            LitheTreeListSelection.select(
                "b", in: rows, selected: ["b", "c", "d"], anchor: "b", extending: true, toggling: false) == ["b"])
        #expect(
            LitheTreeListSelection.select("d", in: rows, selected: ["a"], anchor: "c", extending: true, toggling: true)
                == ["a", "c", "d"])
        #expect(
            LitheTreeListSelection.select(
                "a", in: rows, selected: ["a", "d"], anchor: "a", extending: false, toggling: true) == ["d"])
        #expect(
            LitheTreeListSelection.select(
                "b", in: rows, selected: ["a"], anchor: "removed", extending: true, toggling: false) == ["b"])
        #expect(
            LitheTreeListSelection.select(
                "removed", in: rows, selected: ["a"], anchor: "a", extending: false, toggling: false) == ["a"])
    }

    @Test func growingRangesRevealTheCursorRatherThanTheirAnchor() {
        let visible = ["a", "b", "c", "d"]
        #expect(
            LitheTreeListSelection.revealTarget(cursor: "d", selected: ["a", "b", "c", "d"], visible: visible) == "d")
        #expect(LitheTreeListSelection.revealTarget(cursor: "a", selected: ["c"], visible: visible) == "c")
        #expect(
            LitheTreeListSelection.revealTarget(cursor: "removed", selected: ["removed", "c"], visible: visible) == "c")
        #expect(LitheTreeListSelection.revealTarget(cursor: "a", selected: [], visible: visible) == nil)
    }

    @Test func navigationUsesVisibleHierarchyAndStopsAtBounds() {
        let rows: [LitheTreeListHierarchy] = [
            .init(isBranch: true, isExpanded: true), .init(depth: 1),
            .init(depth: 1, isBranch: true), .init(),
        ]
        #expect(LitheTreeListNavigation.resolve(.up, current: nil, rows: rows) == .select(3))
        #expect(LitheTreeListNavigation.resolve(.down, current: nil, rows: rows) == .select(0))
        #expect(LitheTreeListNavigation.resolve(.up, current: 0, rows: rows) == .select(0))
        #expect(LitheTreeListNavigation.resolve(.down, current: 3, rows: rows) == .select(3))
        #expect(LitheTreeListNavigation.resolve(.right, current: 0, rows: rows) == .select(1))
        #expect(LitheTreeListNavigation.resolve(.left, current: 2, rows: rows) == .select(0))
        #expect(LitheTreeListNavigation.resolve(.right, current: 2, rows: rows) == .expand(2, true))
        #expect(LitheTreeListNavigation.resolve(.left, current: 0, rows: rows) == .expand(0, false))
        #expect(LitheTreeListNavigation.resolve(.right, current: 1, rows: rows) == nil)
        #expect(LitheTreeListNavigation.resolve(.down, current: 0, rows: []) == nil)
    }

    @Test func branchActivationExpandsWhileLeavesKeepTheirAction() {
        var expansions: [Bool] = []
        var activations = 0
        let expand: (Bool) -> Void = { expansions.append($0) }
        let activate = { activations += 1 }
        LitheTreeListHierarchy(isBranch: true).activate(onExpansion: expand, onActivate: activate)
        LitheTreeListHierarchy(isBranch: true, isExpanded: true)
            .activate(onExpansion: expand, onActivate: activate)
        #expect(expansions == [true, false])
        #expect(activations == 0)
        LitheTreeListHierarchy().activate(onExpansion: expand, onActivate: activate)
        #expect(expansions == [true, false])
        #expect(activations == 1)
        LitheTreeListHierarchy(isBranch: true).activate(onExpansion: nil, onActivate: activate)
        #expect(activations == 2)
    }

    @Test func collapsedBranchesDoNotBuildHiddenDescendants() {
        var childBuilds = 0
        let closed = LitheTreeListNode(id: "root", isExpanded: false) {
            Text("Root")
        } children: {
            childBuilds += 1
            return [LitheTreeListNode(id: "child") { Text("Child") }]
        }
        #expect(LitheTreeListNode.visible([closed]).map(\.id) == ["root"])
        #expect(childBuilds == 0)
        var opened = closed
        opened.isExpanded = true
        let visible = LitheTreeListNode.visible([opened])
        #expect(visible.map(\.id) == ["root", "child"])
        #expect(visible.map(\.depth) == [0, 1])
        #expect(childBuilds == 1)
    }

    @Test func mountedListExposesSelectionAndPreservesEmbeddedActions() async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        let state = TreeListInteractionState()
        let host = NSHostingView(
            rootView: LitheTreeList(
                ["a", "b", "c", "d"], id: \.self,
                selection: Binding(get: { state.selected }, set: { state.selected = $0 }),
                onActivate: { state.activated.append($0) }
            ) { value in
                HStack {
                    Text(value).accessibilityIdentifier("row-label-" + value)
                    if value == "a" {
                        Button("Refresh") { state.activated.append("refresh") }
                            .accessibilityIdentifier("embedded-refresh")
                    }
                }
            }
            .frame(width: 260, height: 180).background(LitheTheme.editor))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 260, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func find(_ value: Any, id: String? = nil, containingText text: String? = nil) -> AnyObject? {
            let accessible = value as AnyObject
            let children = accessible.accessibilityChildren?() ?? []
            if let id, accessible.accessibilityIdentifier?() == id { return accessible }
            if let text, accessible.accessibilityRole?() == .button,
                children.contains(where: {
                    ($0 as AnyObject).accessibilityIdentifier?() == "row-label-" + text
                })
            {
                return accessible
            }
            return children.lazy.compactMap { find($0, id: id, containingText: text) }.first
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        var row: AnyObject?
        repeat {
            host.layoutSubtreeIfNeeded()
            row = find(host, containingText: "b")
            if row != nil { break }
            await Task.yield()
        } while clock.now < deadline
        let selected = try #require(row)
        #expect(selected.accessibilityPerformPress?() == true)
        #expect(state.selected == ["b"])
        let refresh = try #require(find(host, id: "embedded-refresh"))
        #expect(refresh.accessibilityPerformPress?() == true)
        #expect(state.activated == ["refresh"])
        #expect(state.selected == ["b"])

    }

    @Test func productRowsCannotUseTheRetiredStyleRecipe() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Lithe")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var failures: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(".litheTreeRow(") || source.contains(".litheSelectionRow(") {
                failures.append(file.lastPathComponent)
            }
            if file.lastPathComponent != "LitheTreeList.swift", source.contains("LitheTreeListRowSurface(") {
                failures.append(file.lastPathComponent)
            }
        }
        #expect(failures.isEmpty, "Tree/list callers must use LitheTreeList: \(failures)")
    }
}

@MainActor
private final class TreeListInteractionState: ObservableObject {
    @Published var selected: Set<String> = []
    var activated: [String] = []
}

@MainActor
struct DependencyTreePresentationTests {
    @Test func cancelledServiceCannotOverwriteANewerLoadOrUnmount() async throws {
        let state = DependencyTreePresentation()
        let started = TestGate()
        let release = TestGate()
        defer {
            started.open()
            release.open()
            state.close()
        }
        state.update("service") {
            $0.expanded = true
            $0.expandedNodeIDs = ["dependency"]
        }
        let oldGeneration = state.begin("service")
        var wasCancelled = false
        let oldTask = Task { @MainActor in
            started.open()
            _ = await release.waitUntilOpen()
            wasCancelled = Task.isCancelled
        }
        defer { oldTask.cancel() }
        state.retain(oldTask, for: "service")
        #expect(await started.waitUntilOpen())
        let nextGeneration = state.begin("service")
        state.finish("service", generation: oldGeneration, graph: nil, error: "stale")
        #expect(state.state(for: "service").resolving)
        #expect(state.state(for: "service").error == nil)
        state.finish("service", generation: nextGeneration, graph: nil, error: "current")
        #expect(state.state(for: "service").error == "current")
        state.close()
        state.finish("service", generation: nextGeneration, graph: nil, error: "late")
        #expect(state.state(for: "service").error == "current")
        #expect(state.state(for: "service").expanded)
        state.invalidate()
        #expect(state.state(for: "service").error == nil)
        #expect(state.state(for: "service").expandedNodeIDs == ["dependency"])
        release.open()
        await oldTask.value
        #expect(wasCancelled)
        state.retainServices([])
        #expect(!state.state(for: "service").expanded)
    }
}

@MainActor
struct LitheTreeListViewportTests {
    @Test func nativePointerAdapterKeepsShortTreesAtTheTop() throws {
        let probe = TreeListViewportProbeStore()
        let host = NSHostingView(
            rootView: LitheTreeList(
                ["first", "second"], id: \.self,
                selection: .constant(Set<String>()),
                native: LitheTreeListNativeInteraction(
                    copy: {}, paste: {}, selectAll: {}, navigate: { _, _ in nil }, isSelected: { _ in false })
            ) { value in
                Text(value).background { if value == "first" { TreeListViewportProbe(store: probe) } }
            }.frame(width: 300, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let firstRow = try #require(probe.view)
        let frame = host.convert(firstRow.bounds, from: firstRow)
        let top = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        #expect(top >= LitheTheme.Tree.verticalInset)
        #expect(top < LitheTheme.Tree.rowHeight, "A short two-axis tree must not center its rows in the viewport")
    }

    @Test func latestOutsidePointerReleasesFocusButUnmountedCallbacksCannot() {
        var active = false
        var ownsFocus = true
        var scheduled: [() -> Void] = []
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let coordinator = LitheToolWindowActivityTracker.Coordinator(
            isActive: Binding(get: { active }, set: { active = $0 }),
            onPointerActivity: { if !$0 { ownsFocus = false } }, schedule: { scheduled.append($0) })
        coordinator.view = view
        defer {
            coordinator.stopObservingFocus()
            window.contentView = nil
            window.close()
        }
        func drain() {
            let callbacks = scheduled
            scheduled.removeAll()
            callbacks.forEach { $0() }
        }
        coordinator.queuePointerActivity(false)
        #expect(ownsFocus, "Focus changes must be deferred out of the native callback")
        drain()
        #expect(!ownsFocus)
        ownsFocus = true
        coordinator.queuePointerActivity(false)
        coordinator.queuePointerActivity(true)
        drain()
        #expect(ownsFocus, "An older outside click must not override the latest click inside")
        coordinator.queuePointerActivity(false)
        coordinator.stopObservingFocus()
        drain()
        #expect(ownsFocus, "Unmount invalidates deferred pointer ownership along with activity")
    }
}

@MainActor
private final class TreeListViewportProbeStore {
    weak var view: NSView?
}

private struct TreeListViewportProbe: NSViewRepresentable {
    let store: TreeListViewportProbeStore
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        store.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
