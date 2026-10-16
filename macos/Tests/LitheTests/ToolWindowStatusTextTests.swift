import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Tool-window StatusText", .serialized)
struct ToolWindowStatusTextTests {
    @Test(arguments: [false, true], ["Frames are not available", "Pause the process to inspect variables", "Select a stack frame to inspect variables"])
    func nativeTextUsesSharedMetricsAndAboveCenterPlacement(dark: Bool, message: String) throws {
        let host = NSHostingView(rootView: LitheToolWindowStatusText(LocalizedStringKey(message))
            .frame(width: 600, height: 300).background(Color.black)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "en")))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var ink = NSRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.redComponent > 0.05 {
                    ink = ink.union(NSRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        #expect(!ink.isNull)
        let scaleX = CGFloat(bitmap.pixelsWide) / 600
        let scaleY = CGFloat(bitmap.pixelsHigh) / 300
        #expect(abs(ink.midX / scaleX - 300) < 3)
        let expectedY = (300 - LitheTheme.ToolWindowEmptyState.rowHeight) / 3 + LitheTheme.ToolWindowEmptyState.rowHeight / 2
        #expect(abs(ink.midY / scaleY - expectedY) < 4)
        #expect(ink.height / scaleY <= LitheTheme.ToolWindowEmptyState.rowHeight)
    }

    @Test func narrowStatusClipsWithoutShrinkingOrWrappingText() throws {
        let host = NSHostingView(rootView: LitheToolWindowStatusText("Frames are not available")
            .frame(width: 60, height: 45).background(Color.black))
        host.frame = NSRect(x: 0, y: 0, width: 60, height: 45)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == NSSize(width: 60, height: 45))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let rows = (0..<bitmap.pixelsHigh).filter { y in
            (0..<bitmap.pixelsWide).contains { x in
                (bitmap.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.05
            }
        }
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        let scale = CGFloat(bitmap.pixelsHigh) / 45
        #expect(CGFloat(last - first + 1) / scale <= LitheTheme.ToolWindowEmptyState.rowHeight)
        #expect(CGFloat(last - first + 1) / scale >= 8)
        #expect(abs(CGFloat(first + last + 1) / (2 * scale) - 18.5) < 4)
    }
}
