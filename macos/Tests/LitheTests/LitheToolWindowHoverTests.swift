import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct LitheToolWindowHoverTests {
    @Test(arguments: [false, true], [ColorScheme.dark, .light])
    func toolbarActionVisibilityUsesTheWholePaneHoverEnvironment(hovered: Bool, scheme: ColorScheme) throws {
        let content = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        .frame(width: 16, height: 16)
        .modifier(LitheToolWindowHoverAction())
        .frame(width: 32, height: 32)
        .background(Color.white)
        .environment(\.isToolWindowHovered, hovered)
        .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.display()
        host.layoutSubtreeIfNeeded()
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        // Capture the window frame so SwiftUI focus/opacity layers are composited.
        // Use hue dominance because the native capture carries the display's HDR profile.
        var redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > color.greenComponent + 0.3, color.redComponent > color.blueComponent + 0.3, color.alphaComponent > 0.99 {
                    redPixels += 1
                }
            }
        }
        #expect(hovered ? redPixels > 100 : redPixels == 0, "Rendered red action pixels: \(redPixels)")
    }
}
