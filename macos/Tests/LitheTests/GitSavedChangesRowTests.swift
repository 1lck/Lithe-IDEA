import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct GitSavedChangesRowTests {
    @Test(arguments: [ColorScheme.dark, .light])
    func savedRowExpandsWithoutMovingTheListAndKeepsClickAction(scheme: ColorScheme) throws {
        var clicks = 0
        let host = NSHostingView(rootView: GitSavedChangesRow(accessibilityTitle: "Saved change", onPress: { clicks += 1 }) { expanded, _ in
            HStack {
                Text("search-replace-before-upstream-sync-20260913")
                if expanded { Text("2026/09/13 22:10").fixedSize() }
                Text("codex/search-replace-style")
            }.font(LitheTheme.uiFont(size: 13)).lineLimit(1)
                .fixedSize(horizontal: expanded, vertical: true)
        }.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> BranchPopupRowControl? {
            (view as? BranchPopupRowControl) ?? view.subviews.lazy.compactMap(find).first
        }
        let row = try #require(find(host))
        let frame = row.frame
        row.mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)))
        let expansion = try #require(window.childWindows?.first(where: { $0.isVisible }))
        #expect(expansion.frame.width > frame.width)
        #expect(row.frame == frame)
        #expect(!expansion.isKeyWindow)
        row.performClick(nil)
        #expect(clicks == 1)
        #expect(window.childWindows?.isEmpty != false)
    }
}
