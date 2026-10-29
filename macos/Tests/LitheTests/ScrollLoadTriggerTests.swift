import AppKit
import SwiftUI
import Testing
@testable import Lithe

@Suite("Viewport continuation trigger")
@MainActor
struct ScrollLoadTriggerTests {
    @Test(arguments: [false, true])
    func nativeViewportBoundsGateRequestsAndPreserveTheOffset(dark: Bool) async throws {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 600, height: 2_000))
        let probe = LitheScrollLoadTrigger.Probe(frame: NSRect(x: 0, y: 1_999, width: 600, height: 1))
        document.addSubview(probe)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = scroll
        window.orderFront(nil)
        defer { probe.detach(); window.contentView = nil; window.close() }
        var requests = 0
        func configure(_ cursor: String?, enabled: Bool = true) {
            probe.configure(continuationID: cursor, isEnabled: enabled, load: { requests += 1 })
        }
        scroll.layoutSubtreeIfNeeded()
        configure("page1")
        await drainViewportQueue()
        #expect(requests == 0, "A mounted non-lazy footer must not fetch while offscreen")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_600))
        scroll.reflectScrolledClipView(scroll.contentView)
        await drainViewportQueue()
        #expect(requests == 1)
        configure("page1")
        await drainViewportQueue()
        #expect(requests == 1, "Bounds/layout updates cannot duplicate an edge request")
        configure("page2", enabled: false)
        await drainViewportQueue()
        #expect(requests == 1, "Loading or failed lists must pause automatic continuation")

        let offset = scroll.contentView.bounds.origin
        document.setFrameSize(NSSize(width: 600, height: 3_000))
        probe.setFrameOrigin(NSPoint(x: 0, y: 2_999))
        configure("page2")
        await drainViewportQueue()
        #expect(requests == 1)
        #expect(scroll.contentView.bounds.origin == offset)
        // Resizing alone can bring the edge inside the viewport.
        window.setContentSize(NSSize(width: 600, height: 1_400))
        scroll.layoutSubtreeIfNeeded()
        await drainViewportQueue()
        #expect(scroll.contentView.bounds.height == 1_400)
        #expect(requests == 2)
        configure(nil)
        await drainViewportQueue()
        #expect(requests == 2)

        scroll.contentView.scroll(to: .zero)
        document.setFrameSize(NSSize(width: 600, height: 100))
        probe.setFrameOrigin(NSPoint(x: 0, y: 99))
        configure("new-context/page1")
        await drainViewportQueue()
        #expect(requests == 3, "Short lists fill the viewport without requiring a wheel event")
        probe.removeFromSuperview()
        configure("detached/page")
        await drainViewportQueue()
        #expect(requests == 3)
        #expect(probe.hitTest(.zero) == nil)
    }

    @Test
    func productionSwiftUIFooterFindsItsNativeViewport() async throws {
        var requests = 0
        let host = NSHostingView(rootView: ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 2_000)
                LitheScrollLoadTrigger(continuationID: "page1", isEnabled: true, load: { requests += 1 })
                    .frame(height: 1)
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await drainViewportQueue()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let probe = try #require(descendants(host).compactMap { $0 as? LitheScrollLoadTrigger.Probe }.first)
        let scroll = try #require(probe.enclosingScrollView)
        #expect(requests == 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_800))
        scroll.reflectScrolledClipView(scroll.contentView)
        await drainViewportQueue()
        #expect(requests == 1)
    }
}

@MainActor
private func drainViewportQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
