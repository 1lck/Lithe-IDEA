import AppKit
import CoreGraphics
import QuartzCore
import LitheTestDesktopIsolation
import Testing

@MainActor
@Suite("Test desktop isolation", .serialized)
struct DesktopIsolationTests {
    @Test func bootstrapHonorsTheRequestedPresentationMode() {
        let environment = ProcessInfo.processInfo.environment
        let visible = environment["LITHE_TEST_WINDOW_MODE"] == "visible"
            || environment["LITHE_RUN_GIT_COMPOSITOR_TESTS"] == "1"
        #expect(LitheTestDesktopIsolationEnabled() == !visible)
    }

    @Test func nativeWindowRemainsOrderedAndDrawsWithoutDesktopPixels() async throws {
        // Unbundled Swift Testing hosts can prohibit native WindowServer presentation.
        // Allow a real desktop window for this integration boundary without a Dock icon.
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        defer { application.setActivationPolicy(policy) }
        let window = makeWindow()
        defer { window.contentView = nil; window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 140))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        #expect(window.isVisible, "Isolation must retain real window ordering")
        let info = try #require(await publishedWindowInfo(window),
            "WindowServer did not publish native window \(window.windowNumber) within 2 seconds")
        let alpha = try #require(info[kCGWindowAlpha as String] as? Double)
        #expect(alpha == (LitheTestDesktopIsolationEnabled() ? 0 : 1))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        let red = try #require(NSColor.red.usingColorSpace(bitmap.colorSpace))
        #expect(abs(pixel.redComponent - red.redComponent) < 0.02
            && abs(pixel.greenComponent - red.greenComponent) < 0.02
            && abs(pixel.blueComponent - red.blueComponent) < 0.02,
                "WindowServer transparency must not erase the native view snapshot")
    }

    @Test func nativeMouseEventsStillReachTheResponder() throws {
        let window = makeWindow()
        defer { window.contentView = nil; window.close() }
        let view = IsolationMouseView(frame: NSRect(x: 0, y: 0, width: 240, height: 140))
        window.contentView = view
        window.orderFront(nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 56),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        #expect(view.downs == 1 && view.ups == 1)
    }

    @Test func laterOpacityRequestsCannotExposeWindowAndRemainAssertable() {
        let window = makeWindow()
        defer { window.close() }
        window.alphaValue = 0.9
        window.orderFrontRegardless()
        #expect(LitheTestRequestedWindowAlpha(window) == 0.9,
                "Product opacity requests remain available to appearance assertions")
        #expect(window.alphaValue == (LitheTestDesktopIsolationEnabled() ? 0 : 0.9))
        window.orderOut(nil)
        #expect(!window.isVisible, "Native dismissal must still remove the real window")
    }

    @Test func isolatedApplicationDoesNotReplaceTheForegroundApplication() {
        guard LitheTestDesktopIsolationEnabled() else { return }
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        defer { application.setActivationPolicy(policy) }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        application.activate(ignoringOtherApps: true)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
    }

    private func makeWindow() -> NSWindow {
        // Swift Testing does not create an AppKit application before the first native fixture.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 140),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func publishedWindowInfo(_ window: NSWindow) async -> [String: Any]? {
        // Native window geometry/opacity is committed asynchronously. Observe the actual
        // WindowServer entry with a local deadline rather than waiting an arbitrary delay.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            renderNativeFrame()
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow,
                CGWindowID(window.windowNumber)) as? [[String: Any]]
            if let entry = info?.first { return entry }
            await Task.yield()
        }
        return nil
    }

    private func renderNativeFrame() {
        // Process one native update with zero wait, then commit its presentation transaction.
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
        CATransaction.flush()
    }
}

@MainActor
private final class IsolationMouseView: NSView {
    var downs = 0
    var ups = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
}
