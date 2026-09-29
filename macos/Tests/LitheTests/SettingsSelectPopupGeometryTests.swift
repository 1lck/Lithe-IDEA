import AppKit
import SwiftUI
import Testing
@testable import Lithe

@Suite("Settings select popup")
struct SettingsSelectPopupGeometryTests {
    @MainActor
    @Test
    func popupClosesOnItsTriggerAndBlankSpaceButSwitchesToAnotherSelect() async throws {
        let host = NSHostingView(rootView: HStack(spacing: 20) {
            LitheSettingsSelect(
                selection: .constant("First"), options: ["First", "Another"],
                width: 180, accessibilityLabel: "First select", title: { $0 }
            )
            LitheSettingsSelect(
                selection: .constant("Second"), options: ["Second", "Another"],
                width: 180, accessibilityLabel: "Second select", title: { $0 }
            )
            Spacer()
        }.frame(width: 450, height: 120, alignment: .topLeading))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 450, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func popup() -> NSPanel? {
            NSApp.windows.compactMap { $0 as? NSPanel }.first {
                $0.isVisible && NSStringFromClass(type(of: $0)).hasSuffix("LitheSettingsSelectPopupPanel")
            }
        }

        func click(_ point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: host.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                NSApp.sendEvent(event)
            }
        }
        defer {
            if popup() != nil { try? click(NSPoint(x: 420, y: 80)) }
            window.orderOut(nil)
            window.close()
        }

        func waitForPopup(_ condition: @escaping (NSPanel?) -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while clock.now < deadline {
                if condition(popup()) { return true }
                await Task.yield()
            }
            return condition(popup())
        }

        try click(NSPoint(x: 80, y: 14))
        #expect(await waitForPopup { $0 != nil })
        let firstFrame = try #require(popup()?.frame)
        try click(NSPoint(x: 80, y: 14))
        #expect(await waitForPopup { $0 == nil }, "Clicking the open select must close it")

        try click(NSPoint(x: 80, y: 14))
        #expect(await waitForPopup { $0 != nil })
        try click(NSPoint(x: 280, y: 14))
        #expect(await waitForPopup { ($0?.frame.minX ?? 0) > firstFrame.minX + 100 },
                "The second select must replace the first popup")

        try click(NSPoint(x: 420, y: 80))
        #expect(await waitForPopup { $0 == nil }, "Blank space must close the popup")
    }

    @MainActor
    @Test
    func onlyLeftClickOnOriginalControlDefersDismissal() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = window.convertToScreen(NSRect(x: 20, y: 200, width: 190, height: 28))

        func click(at point: NSPoint, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1
            ))
        }

        #expect(LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 100, y: 214)), anchorWindow: window, anchorFrame: anchor
        ))
        #expect(!LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 260, y: 214)), anchorWindow: window, anchorFrame: anchor
        ))
        #expect(!LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 300, y: 50)), anchorWindow: window, anchorFrame: anchor
        ))
        #expect(!LitheSettingsSelectPopupGeometry.isAnchorClick(
            try click(at: NSPoint(x: 100, y: 214), type: .rightMouseDown),
            anchorWindow: window, anchorFrame: anchor
        ))
    }

    @Test
    func opensBelowTheControlWithoutAnArrowGap() {
        let anchor = CGRect(x: 100, y: 500, width: 190, height: 28)
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: anchor,
            size: CGSize(width: 190, height: 90),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(frame == CGRect(x: 100, y: 408, width: 190, height: 90))
    }

    @Test
    func flipsAboveAndClampsToTheVisibleScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: CGRect(x: 950, y: 30, width: 190, height: 28),
            size: CGSize(width: 190, height: 90),
            visibleFrame: visible
        )
        #expect(frame == CGRect(x: 804, y: 60, width: 190, height: 90))
        #expect(visible.contains(frame))
    }

    @Test
    func shrinksToAvailableSpaceWithoutCoveringTheControl() {
        let anchor = CGRect(x: 100, y: 246, width: 190, height: 28)
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: anchor,
            size: CGSize(width: 190, height: 252),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 500)
        )
        #expect(frame == CGRect(x: 100, y: 6, width: 190, height: 238))
        #expect(!frame.intersects(anchor))
    }
}
