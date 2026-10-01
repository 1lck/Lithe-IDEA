import AppKit
import SwiftUI
import Testing
@testable import Lithe

@Suite("Shared IDEA scrollbar", .serialized)
@MainActor
struct LitheScrollBarStyleTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func nativeProductRailAndThumbUseSharedPainter(appearance: NSAppearance.Name) async throws {
        let host = NSHostingView(rootView: ScrollView(.vertical) {
            Color.clear.frame(height: 1_000)
                .litheScrollViewChrome(hideHorizontal: true, alwaysShowVertical: true)
        }.background(LitheTheme.Diff.background)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scroll.verticalScroller as? LitheScrollViewChrome.CompactScroller)
        #expect(scroll.horizontalScroller == nil)
        #expect(scroller.knobProportion < 1)
        #expect(scroller.bounds.width == LitheScrollBarStyle.thickness)
        let original = scroller.doubleValue
        for hover in [false, true] {
            scroller.setHovered(hover, animated: false)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let rect = LitheScrollBarStyle.thumbRect(in: scroller.bounds, knob: scroller.rect(for: .knob),
                role: .product, hover: hover ? 1 : 0, opaque: true)
            let point = host.convert(NSPoint(x: rect.midX, y: rect.midY), from: scroller)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let pixel = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int((host.isFlipped ? point.y : host.bounds.height - point.y) * scale)))
            let dark = appearance == .darkAqua
            let alpha: CGFloat = dark ? (hover ? 140 : 89) / 255 : (hover ? 128 : 51) / 255
            // Persistent Mac tracks remain transparent even on hover.
            let base: CGFloat = dark ? 26 / 255 : 1
            let track = base
            let expected = track * (1 - alpha) + (dark ? 128.0 / 255 : 0) * alpha
            #expect(abs(pixel.greenComponent - expected) < 0.03, "Actual scroll-view thumb: \(pixel), expected \(expected)")
            #expect(scroller.doubleValue == original, "Hover must never scroll")
            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("scrollbar-\(dark)-\(hover).png"))
            }
        }
    }

    @Test
    func editorRailUsesWideDiffMarkersAndMirroredThumb() {
        let bounds = NSRect(x: 0, y: 0, width: LitheScrollBarStyle.editorThickness, height: 200)
        let knob = NSRect(x: 0, y: 30, width: bounds.width, height: 80)
        let right = LitheScrollBarStyle.thumbRect(in: bounds, knob: knob, role: .editor, hover: 0)
        let left = LitheScrollBarStyle.thumbRect(in: bounds, knob: knob, role: .editor, hover: 0, mirrored: true)
        #expect(right.width == 9 && right.midX == 11)
        #expect(left.midX == bounds.width - right.midX)
        #expect(right.minX > 2 && left.maxX < bounds.width - 2)
        #expect(LitheScrollBarStyle.thumbRect(in: bounds, knob: knob, role: .editor, hover: 1).width == 12)
        #expect(LitheScrollBarStyle.thumbRect(in: bounds, knob: knob, role: .editor, hover: 0, dark: false).width == 7)
        #expect(LitheScrollBarStyle.thumbRect(in: bounds, knob: knob, role: .editor, hover: 1, dark: false).width == 10)
        let stripe = DiffStripeScroller(frame: bounds)
        stripe.side = .right; stripe.sourceHeight = 100
        let change = DiffSplitLayout.Transition(id: "paired", kind: .changed,
            leftRange: 22...44, rightRange: 22...66)
        #expect(stripe.markerRect(change).minY == 22 && stripe.markerRect(change).height == 22,
            "A short file retains actual source Y positions instead of stretching marks")
        #expect(stripe.markerRect(change).width == 14 && stripe.markerRect(change).minX == 4)
        stripe.side = .left
        #expect(stripe.markerRect(change).minX == 0 && stripe.markerRect(change).height == 2,
            "Single-line replacements use the minimum-height wide error stripe")
        stripe.side = .right
        stripe.sourceHeight = 1_000
        #expect(stripe.markerRect(change).minY == 4
            && stripe.markerRect(change).height == 4)
    }

}
