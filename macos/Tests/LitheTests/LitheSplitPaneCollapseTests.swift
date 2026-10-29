import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Split pane collapse")
struct LitheSplitPaneCollapseTests {
    @Test("Empty and multi-view pane builders retain separate pane bounds",
          arguments: [0, 1, 2], [LitheSplitAxis.horizontal, .vertical])
    func paneBuildersKeepSeparateBounds(childCount: Int, axis: LitheSplitAxis) throws {
        let surfaces = CollapseSurfaceRecorder()
        let host = NSHostingView(rootView: LitheSplitPaneView(
            axis: axis, placement: .leading, defaultSize: 200, minimum: 72, maximum: 400,
            flexibleMinimum: 100, sized: {
                ForEach(0..<childCount, id: \.self) { index in
                    CollapseSurface(name: "result-\(index)", recorder: surfaces)
                }
            }, flexible: {
                CollapseSurface(name: "preview", recorder: surfaces)
                Text("Preview footer").frame(height: 22)
            }))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let preview = try #require(surfaces.views["preview"]?.first)
        let previewFrame = preview.convert(preview.bounds, to: host)
        #expect(previewFrame.width > 0 && previewFrame.height > 0)
        #expect(host.bounds.contains(previewFrame))
        #expect((axis == .horizontal ? previewFrame.width : previewFrame.height) <= 395)
        for index in 0..<childCount {
            let result = try #require(surfaces.views["result-\(index)"]?.first)
            let resultFrame = result.convert(result.bounds, to: host)
            #expect(resultFrame.width > 0 && resultFrame.height > 0)
            #expect(host.bounds.contains(resultFrame))
            #expect(!resultFrame.intersects(previewFrame))
        }
    }

    @Test("A declared page size avoids content-driven intrinsic sizing while panes still follow window bounds",
          arguments: [LitheSplitAxis.horizontal, .vertical])
    func declaredPageSizePreservesPaneGeometry(axis: LitheSplitAxis) throws {
        let surfaces = CollapseSurfaceRecorder()
        let host = NSHostingView(rootView: LitheSplitPaneView(
            axis: axis, placement: .leading, defaultSize: 220, minimum: 30, maximum: 400,
            idealSize: CGSize(width: 900, height: 617),
            sized: { CollapseSurface(name: "sidebar", recorder: surfaces) },
            flexible: {
                CollapseSurface(name: "content", recorder: surfaces)
                    .frame(idealWidth: 1800, idealHeight: 2000)
            }))
        #expect(host.fittingSize == CGSize(width: 900, height: 617))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1200, height: 800)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            let sidebar = try #require(surfaces.views["sidebar"]?.first)
            let content = try #require(surfaces.views["content"]?.first)
            if axis == .horizontal {
                #expect(sidebar.bounds.width == 220)
                #expect(content.bounds.width == size.width - 220 - SplitHandleView.thickness)
                #expect(content.bounds.height == size.height)
            } else {
                #expect(sidebar.bounds.height == 220)
                #expect(content.bounds.height == size.height - 220 - SplitHandleView.thickness)
                #expect(content.bounds.width == size.width)
            }
        }
        #expect(surfaces.views.values.allSatisfy { $0.count == 1 })
    }

    @Test("Release holds the final size until the host returns its committed value",
          arguments: [LitheSplitAxis.horizontal, .vertical])
    func releaseWaitsForCommittedSize(axis: LitheSplitAxis) async throws {
        let surfaces = CollapseSurfaceRecorder()
        var committed: CGFloat?
        func content(_ size: CGFloat) -> some View {
            LitheSplitPaneView(axis: axis, placement: .leading,
                defaultSize: size, minimum: 30, maximum: 600,
                onCommit: { committed = $0 },
                sized: { CollapseSurface(name: "primary", recorder: surfaces) },
                flexible: { CollapseSurface(name: "terminal", recorder: surfaces) })
        }
        let host = NSHostingView(rootView: content(200))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let handle = try #require(descendants(host).compactMap { $0 as? SplitHandleInteractionView }.first)
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, distance: CGFloat = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: origin.x + (axis == .horizontal ? distance : 0),
                                  y: origin.y - (axis == .vertical ? distance : 0)),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        func settle(resizing: Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            repeat {
                host.layoutSubtreeIfNeeded()
                if surfaces.resizing["primary"] == resizing { return }
                await Task.yield()
            } while clock.now < deadline
            Issue.record("Split did not reach resizing=\(resizing)")
        }
        let primary = try #require(surfaces.views["primary"]?.first)
        func extent() -> CGFloat { axis == .horizontal ? primary.bounds.width : primary.bounds.height }
        handle.mouseDown(with: try event(.leftMouseDown))
        try await settle(resizing: true)
        handle.mouseDragged(with: try event(.leftMouseDragged, distance: 120))
        handle.mouseUp(with: try event(.leftMouseUp, distance: 120))
        try await settle(resizing: false)
        #expect(committed == 320)
        // Deliberately withhold the host echo: release must not restore the old 200pt.
        #expect(extent() == 320)
        host.rootView = content(try #require(committed))
        host.layoutSubtreeIfNeeded()
        #expect(extent() == 320)
        host.rootView = content(360)
        host.layoutSubtreeIfNeeded()
        #expect(extent() == 360)
        #expect(surfaces.views.values.allSatisfy { $0.count == 1 })
    }

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
                                        .frame(height: LitheTheme.Tree.rowHeight)
                                        .modifier(LitheTreeListRowSurface(isSelected: false, isFocused: false))
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
