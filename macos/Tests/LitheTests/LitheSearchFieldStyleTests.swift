import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Shared search field chrome", .serialized)
struct LitheSearchFieldStyleTests {
    @Test(arguments: [ColorScheme.dark, .light])
    func uncommittedIMETextHidesOnlyItsOwnPlaceholder(scheme: ColorScheme) async throws {
        // A constant binding deliberately stays empty until commit: the prompt
        // must follow the visible field editor, not wait for the bound value.
        let host = NSHostingView(rootView: HStack {
            LitheSearchTextField("Branch or tag", text: .constant("")).litheSearchField().frame(width: 220)
            LitheSearchTextField("Search connections", text: .constant("")).litheSearchField().frame(width: 220)
        }.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 448, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        let fields = fields(in: host).sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
        #expect(fields.count == 2)
        let first = try #require(fields.first)
        let second = try #require(fields.last)
        func placeholderPixels(_ field: NSTextField) throws -> Int {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let rect = field.convert(field.bounds, to: host)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let minY = Int((host.bounds.height - rect.maxY) * scale)
            let maxY = Int((host.bounds.height - rect.minY) * scale)
            // Compare glyphs with this bitmap's blank field background so the
            // window's display color profile cannot affect the presence check.
            let background = try #require(bitmap.colorAt(x: Int((rect.maxX - 3) * scale), y: (minY + maxY) / 2))
            var count = 0
            // Skip the short composing syllable at the left edge. Remaining
            // prompt glyphs must also disappear, including cached trailing text.
            for y in minY..<maxY {
                for x in Int((rect.minX + 30) * scale)..<Int((rect.maxX - 3) * scale) {
                    let color = try #require(bitmap.colorAt(x: x, y: y))
                    if abs(color.redComponent - background.redComponent) > 0.05
                        || abs(color.greenComponent - background.greenComponent) > 0.05
                        || abs(color.blueComponent - background.blueComponent) > 0.05 { count += 1 }
                }
            }
            return count
        }
        let clock = ContinuousClock()
        func settle(_ field: NSTextField, visible: Bool) async throws {
            let deadline = clock.now.advanced(by: .seconds(1))
            while clock.now < deadline {
                if try (placeholderPixels(field) > 10) == visible { return }
                await Task.yield()
            }
            #expect(try (placeholderPixels(field) > 10) == visible)
        }
        #expect(try placeholderPixels(first) > 10)
        #expect(try placeholderPixels(second) > 10)
        #expect(window.makeFirstResponder(first))
        let editor = try #require(first.currentEditor() as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        try await settle(first, visible: false)
        #expect(try placeholderPixels(first) == 0)
        #expect(try placeholderPixels(second) > 10)

        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        try await settle(first, visible: true)
        #expect(try placeholderPixels(first) > 10)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle(first, visible: false)
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "你")
        #expect(try placeholderPixels(first) == 0)
        #expect(window.makeFirstResponder(second))
        try await settle(first, visible: true)
        let secondEditor = try #require(second.currentEditor() as? NSTextView)
        secondEditor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle(second, visible: false)
        #expect(try placeholderPixels(first) > 10)
        #expect(try placeholderPixels(second) == 0)
    }

    @Test(arguments: [ColorScheme.dark, .light], ["", "typed"])
    func nativeSearchFieldRendersPlaceholderAndEnteredTextColors(scheme: ColorScheme, value: String) throws {
        // ImageRenderer cannot cover AppKit-backed text. Capture the native host
        // so a correct theme token with an ignored prompt style still fails.
        let host = NSHostingView(rootView: LitheSearchTextField("Branch or tag", text: .constant(value))
            .litheSearchField()
            .frame(width: 220)
            .environment(\.colorScheme, scheme))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 36)
        host.layoutSubtreeIfNeeded()
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        let field = try #require(textField(in: host))
        #expect(field.stringValue == value)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let expected: UInt32 = value.isEmpty ? 0x73767C : (scheme == .dark ? 0xD1D3D9 : 0x000000)
        let scale = bitmap.pixelsWide / 220
        var matchingGlyphPixels = 0
        // Ignore the border and anti-aliased edges; fully covered glyph interiors
        // must carry the source color in both themes, with no native substitution.
        for y in (8 * scale)..<(28 * scale) {
            for x in (10 * scale)..<(200 * scale) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(color.redComponent - CGFloat((expected >> 16) & 255) / 255) < 0.01,
                   abs(color.greenComponent - CGFloat((expected >> 8) & 255) / 255) < 0.01,
                   abs(color.blueComponent - CGFloat(expected & 255) / 255) < 0.01 {
                    matchingGlyphPixels += 1
                }
            }
        }
        #expect(matchingGlyphPixels > 10)
    }

    @Test(arguments: [ColorScheme.dark, .light], [false, true])
    func sharedBorderReservesInsetsAndFocusExpandsWithoutResizing(
        scheme: ColorScheme, focused: Bool
    ) throws {
        let renderer = ImageRenderer(content: Color.clear
            .litheSearchField(isFocused: focused)
            .frame(width: 220)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 440)
        #expect(image.height == 72)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        func pixel(_ x: Int, _ y: Int = 36) -> NSColor {
            let offset = (y * image.width + x) * 4
            return NSColor(srgbRed: CGFloat(pixels[offset]) / 255,
                           green: CGFloat(pixels[offset + 1]) / 255,
                           blue: CGFloat(pixels[offset + 2]) / 255,
                           alpha: CGFloat(pixels[offset + 3]) / 255)
        }
        func expectRGB(_ color: NSColor, _ hex: UInt32) {
            #expect(abs(color.redComponent - CGFloat((hex >> 16) & 255) / 255) < 0.01)
            #expect(abs(color.greenComponent - CGFloat((hex >> 8) & 255) / 255) < 0.01)
            #expect(abs(color.blueComponent - CGFloat(hex & 255) / 255) < 0.01)
        }
        // The visible field is 30pt inside a 36pt wrapper. Focus uses the
        // reserved space instead of moving content or stacking another ring.
        #expect(pixel(focused ? 3 : 5).alphaComponent == 0)
        for x in (focused ? 4 : 6)..<8 {
            expectRGB(pixel(x), focused ? 0x3871E1 : (scheme == .dark ? 0x40434A : 0xD1D3D9))
        }
        expectRGB(pixel(12), scheme == .dark ? 0x191A1C : 0xFFFFFF)
        #expect(pixel(focused ? 4 : 6, focused ? 4 : 6).alphaComponent < 0.1)
    }
}
