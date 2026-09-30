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
}

@MainActor
private final class CollapseSurfaceRecorder {
    var views: [String: [NSView]] = [:]
}

private struct CollapseSurface: NSViewRepresentable {
    let name: String
    let recorder: CollapseSurfaceRecorder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        recorder.views[name, default: []].append(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
