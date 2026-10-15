import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite(.serialized)
struct LitheBannerAppearanceTests {
    @Test(arguments: [ColorScheme.dark, .light])
    func statusSurfacesUseCommunityColorsAndWrap(scheme: ColorScheme) throws {
        MacBundledFontRegistry.registerFonts()
        let iconRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for path in LitheBannerStatus.allCases.compactMap(\.iconPath) {
            for asset in [path, LitheIcons.darkIdeaAssetPath(for: path)] {
                #expect(try #require(NSImage(contentsOf: iconRoot.appendingPathComponent(asset))).size == NSSize(width: 16, height: 16))
            }
        }
        let backgrounds: [UInt32] = scheme == .dark
            ? [0x233558, 0x1B283F, 0x26282C, 0x203B2A, 0x44321D, 0x56272B]
            : [0xF7F8FF, 0xF7F8FF, 0xF7F8F9, 0xF5FAF3, 0xFFF6E9, 0xFFF6F5]
        let borders: [UInt32] = scheme == .dark
            ? [0x2E4D89, 0x233558, 0x33353B, 0x29583C, 0x694820, 0x80383E]
            : [0xBDD3FF, 0xD0DFFE, 0xE9EAEE, 0xBBDBC2, 0xF4CD9A, 0xFFC4C5]
        for (index, status) in LitheBannerStatus.allCases.enumerated() {
            for layout in [LitheBannerLayout.inline, .editor] {
                let host = NSHostingView(rootView: LitheBanner(status: status, layout: layout) {
                    Text(String(repeating: "A notice must remain readable. ", count: 8))
                }.frame(width: 320).environment(\.colorScheme, scheme))
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                #expect(host.bounds.width == 320)
                #expect(host.bounds.height > 50)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                func expectColor(_ hex: UInt32, y: CGFloat) throws {
                    let color = try #require(bitmap.colorAt(x: Int(160 * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
                    #expect(abs(color.redComponent - CGFloat((hex >> 16) & 255) / 255) < 0.01)
                    #expect(abs(color.greenComponent - CGFloat((hex >> 8) & 255) / 255) < 0.01)
                    #expect(abs(color.blueComponent - CGFloat(hex & 255) / 255) < 0.01)
                }
                try expectColor(backgrounds[index], y: host.bounds.height - 5)
                try expectColor(borders[index], y: 0)
            }
        }
    }

    @Test
    func sharedNoticeActionsAndDismissRemainClickable() async throws {
        let actions = BannerClickRecorder()
        let dismissals = BannerClickRecorder()
        let host = NSHostingView(rootView: LitheBanner(status: .warning, dismiss: { dismissals.count += 1 }) {
            Text("Actionable notice")
            Button("Retry") { actions.count += 1 }.accessibilityIdentifier("banner-retry")
        }.frame(width: 320))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: host.fittingSize.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let lineHeight = NSLayoutManager().defaultLineHeight(for: LitheTheme.uiNSFont(size: 13))
        let retryPoint = NSPoint(x: LitheTheme.Banner.inset + 16 + LitheTheme.Banner.gap + 15,
                                 y: LitheTheme.Banner.inset + lineHeight + LitheTheme.Banner.gap + lineHeight / 2)
        try clickNativeView(host, at: retryPoint)
        #expect(await awaitChange(on: actions) { actions.count == 1 })
        let closePoint = NSPoint(x: host.bounds.width - LitheTheme.Banner.dismissInset - LitheTheme.Banner.dismissSize / 2,
                                 y: LitheTheme.Banner.dismissInset + LitheTheme.Banner.dismissSize / 2)
        try clickNativeView(host, at: closePoint)
        #expect(await awaitChange(on: dismissals) { dismissals.count == 1 })
    }
}

/// Deliver mouse events to the production SwiftUI hit target; points are measured from its top left.
@MainActor
func clickNativeView(_ host: NSView, at topLeftPoint: NSPoint) throws {
    let window = try #require(host.window)
    let local = NSPoint(x: topLeftPoint.x, y: host.isFlipped ? topLeftPoint.y : host.bounds.height - topLeftPoint.y)
    let point = host.convert(local, to: nil)
    window.makeKeyAndOrderFront(nil)
    window.displayIfNeeded()
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1))
        NSApplication.shared.sendEvent(event)
    }
}

@MainActor
private final class BannerClickRecorder: ObservableObject {
    @Published var count = 0
}
