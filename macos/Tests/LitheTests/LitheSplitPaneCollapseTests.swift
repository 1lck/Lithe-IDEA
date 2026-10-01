import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Split pane collapse")
struct LitheSplitPaneCollapseTests {
    @Test
    func collapseKeepsCommitAndDetailSurfacesMountedAndRestoresWidth() async throws {
        let surfaces = CollapseSurfaceRecorder()
        func content(collapsed: Bool, referenceWidth: CGFloat = 220) -> some View {
            LitheSplitPaneView(
                axis: .horizontal, placement: .leading,
                defaultSize: referenceWidth, minimum: CGFloat(WorkbenchLayout.minimumPaneSize), maximum: 300,
                clipsSizedPane: true, isSizedPaneCollapsed: collapsed,
                sized: { CollapseSurface(name: "branches", recorder: surfaces) },
                flexible: {
                    LitheSplitPaneView(
                        axis: .horizontal, placement: .trailing,
                        defaultSize: 250, minimum: 200, maximum: 350,
                        sized: { CollapseSurface(name: "details", recorder: surfaces) },
                        flexible: { CollapseSurface(name: "commits", recorder: surfaces) }
                    )
                }
            )
        }
        let host = NSHostingView(rootView: content(collapsed: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let branches = try #require(surfaces.views["branches"]?.first)
        let commits = try #require(surfaces.views["commits"]?.first)
        let details = try #require(surfaces.views["details"]?.first)
        let expandedCommitWidth = commits.bounds.width
        #expect(branches.bounds.width == 220)

        // A collapse only changes geometry. Remounting the graph would discard
        // scroll state and pay native view creation costs on every toggle.
        for collapsed in [true, false, true, false] {
            host.rootView = content(collapsed: collapsed)
            host.layoutSubtreeIfNeeded()
            #expect(surfaces.views.values.allSatisfy { $0.count == 1 })
            #expect(branches.bounds.width == (collapsed ? 0 : 220))
            #expect(details.bounds.width == 250)
            #expect(commits.bounds.width == expandedCommitWidth + (collapsed ? 225 : 0))
        }
        // The shared narrow-pane limit must not remount or squeeze the detail surface.
        host.rootView = content(collapsed: false, referenceWidth: CGFloat(WorkbenchLayout.minimumPaneSize))
        host.layoutSubtreeIfNeeded()
        #expect(branches.bounds.width == 30)
        #expect(details.bounds.width == 250)
        #expect(commits.bounds.width == expandedCommitWidth + 190)
        host.rootView = content(collapsed: false)
        host.layoutSubtreeIfNeeded()
        #expect(branches.bounds.width == 220)
        #expect(surfaces.views.values.allSatisfy { $0.count == 1 })
    }

    @Test("An outer drag suspends nested row chrome and restores it without remounting content")
    func outerDragSuspendsRowChrome() async throws {
        let surfaces = CollapseSurfaceRecorder()
        let root = LitheSplitPaneView(axis: .vertical, placement: .leading,
            defaultSize: 100, minimum: 30, maximum: 400,
            sized: { Color.clear },
            flexible: {
                LitheSplitPaneView(axis: .horizontal, placement: .leading,
                    defaultSize: 220, minimum: 30, maximum: 300,
                    sized: {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(0..<69) { index in
                                    Button("codex/branch-\(index)") {}.buttonStyle(.litheNoPress)
                                        .litheTreeRow()
                                        .workbenchHoverHelp(Text("Branch \(index)"))
                                        .litheContextMenu { [.action("Select", action: {})] }
                                        .background(CollapseSurface(name: String(index), recorder: surfaces))
                                }
                            }
                        }.workbenchHoverTooltipScope()
                    },
                    flexible: { Color.clear })
            })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func menuCount() -> Int {
            descendants(host).filter { String(describing: type(of: $0)) == "LitheRightClickCaptureView" }.count
        }
        let menuCountBefore = menuCount()
        #expect(menuCountBefore == 69)
        #expect(surfaces.resizing.values.allSatisfy { !$0 })
        let handle = try #require(descendants(host).compactMap { $0 as? SplitHandleInteractionView }
            .first { $0.axis == .vertical })
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x, y: origin.y + offset),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let clock = ContinuousClock()
        func settle(resizing: Bool) async {
            let deadline = clock.now.advanced(by: .seconds(1))
            while clock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if surfaces.resizing.count == 69,
                   surfaces.resizing.values.allSatisfy({ $0 == resizing }),
                   menuCount() == (resizing ? 0 : menuCountBefore) { return }
                await Task.yield()
            }
        }
        handle.mouseDown(with: try event(.leftMouseDown))
        await settle(resizing: true)
        #expect(surfaces.resizing.values.allSatisfy { $0 })
        #expect(menuCount() == 0)
        let started = clock.now
        for offset in [CGFloat(-40), -80, -120, -80, -40, 0] {
            handle.mouseDragged(with: try event(.leftMouseDragged, offset: offset))
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            #expect(menuCount() == 0)
            #expect(surfaces.views.values.allSatisfy { $0.count == 1 })
        }
        print("GIT_REFERENCE_RESIZE rows=69 events=6 elapsed=\(started.duration(to: clock.now))")
        handle.mouseUp(with: try event(.leftMouseUp))
        await settle(resizing: false)
        #expect(menuCount() == menuCountBefore)
        #expect(surfaces.resizing.values.allSatisfy { !$0 })
        #expect(surfaces.views.values.allSatisfy { $0.count == 1 })
    }
}

@MainActor
private final class CollapseSurfaceRecorder {
    var views: [String: [NSView]] = [:]
    var resizing: [String: Bool] = [:]
}

private struct CollapseSurface: NSViewRepresentable {
    let name: String
    let recorder: CollapseSurfaceRecorder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        recorder.views[name, default: []].append(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.resizing[name] = context.environment.isLithePaneResizing
    }
}
