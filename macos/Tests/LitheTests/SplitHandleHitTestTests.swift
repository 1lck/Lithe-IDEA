import AppKit
import Testing
@testable import Lithe

@MainActor
@Suite("Scoped split handle hit testing", .serialized)
struct SplitHandleHitTestTests {
    @Test
    func forwardingUsesLiveClippingVisibilityAndNativeOrder() throws {
        let registry = SplitHandleHitTestRegistry()
        let window = makeWindow()
        defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        let clip = NSView(frame: NSRect(x: 30, y: 20, width: 100, height: 140))
        clip.clipsToBounds = true
        root.addSubview(clip)
        let first = SplitHandleInteractionView(frame: NSRect(x: 95, y: 0, width: 10, height: 140))
        first.hitTestRegistry = registry
        clip.addSubview(first)
        let surface = NSView(frame: NSRect(x: 10, y: 10, width: 240, height: 180))
        root.addSubview(surface)
        func hit(_ x: CGFloat) -> SplitHandleInteractionView? {
            registry.handle(at: first.convert(NSPoint(x: x, y: 70), to: surface), in: surface)
        }
        #expect(hit(2) === first)
        #expect(hit(8) == nil, "The clipped part must not steal an adjacent pane's input")
        clip.isHidden = true
        #expect(hit(2) == nil)
        clip.isHidden = false
        clip.alphaValue = 0
        #expect(hit(2) == nil)
        clip.alphaValue = 1
        first.isHidden = true
        #expect(hit(2) == nil)
        first.isHidden = false
        let oldPoint = first.convert(NSPoint(x: 2, y: 70), to: surface)
        first.frame.origin.x = 60
        #expect(registry.handle(at: oldPoint, in: surface) == nil)
        #expect(hit(2) === first, "Geometry must follow resize without a stale rectangle cache")
        let second = SplitHandleInteractionView(frame: first.frame)
        second.hitTestRegistry = registry
        clip.addSubview(second)
        #expect(hit(2) === second)
        clip.addSubview(first, positioned: .above, relativeTo: second)
        #expect(hit(2) === first, "Overlapping layout handles follow native stacking, not registration order")
        let internalHandle = SplitHandleInteractionView(frame: first.convert(first.bounds, to: surface))
        internalHandle.hitTestRegistry = registry
        surface.addSubview(internalHandle)
        #expect(hit(2) === first, "Retained content handles must use normal traversal, not override layout handles")
    }

    @Test
    func lookupIsScopedWeakAndFollowsWindowAndRegistryChanges() throws {
        let registry = SplitHandleHitTestRegistry()
        let otherRegistry = SplitHandleHitTestRegistry()
        let window = makeWindow()
        let otherWindow = makeWindow()
        defer {
            window.contentView = nil; window.close()
            otherWindow.contentView = nil; otherWindow.close()
        }
        let root = try #require(window.contentView)
        let otherRoot = try #require(otherWindow.contentView)
        let surface = NSView(frame: root.bounds)
        let otherSurface = NSView(frame: otherRoot.bounds)
        root.addSubview(surface)
        otherRoot.addSubview(otherSurface)
        weak var released: SplitHandleInteractionView?
        autoreleasepool {
            let handle = SplitHandleInteractionView(frame: NSRect(x: 50, y: 0, width: 10, height: 200))
            released = handle
            handle.hitTestRegistry = registry
            root.addSubview(handle)
            let point = NSPoint(x: 55, y: 100)
            #expect(registry.handle(at: point, in: surface) === handle)
            #expect(registry.handle(at: point, in: otherSurface) == nil)
            #expect(otherRegistry.handle(at: point, in: surface) == nil)
            otherRoot.addSubview(handle)
            #expect(registry.handle(at: point, in: surface) == nil)
            #expect(registry.handle(at: point, in: otherSurface) === handle)
            handle.hitTestRegistry = otherRegistry
            #expect(registry.handle(at: point, in: otherSurface) == nil)
            #expect(otherRegistry.handle(at: point, in: otherSurface) === handle)
            handle.removeFromSuperview()
            #expect(otherRegistry.handle(at: point, in: otherSurface) == nil)
            otherRoot.addSubview(handle)
            #expect(otherRegistry.handle(at: point, in: otherSurface) === handle)
            handle.removeFromSuperview()
        }
        #expect(released == nil, "Neither scope may retain an unmounted divider")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
