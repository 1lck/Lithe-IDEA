import AppKit
import Testing
@testable import Lithe

@MainActor
struct TomlIconResourceTests {
    @Test(arguments: [false, true])
    func tomlUsesThemeSpecificOfficialBackground(dark: Bool) throws {
        #expect(LitheIcons.kind(forFilePath: "/fixture/bunfig.toml") == .toml)
        let path = "fileTypes/toml.svg"
        let asset = dark ? LitheIcons.darkIdeaAssetPath(for: path) : path
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        let image = try #require(NSImage(contentsOf: root.appendingPathComponent(asset)))
        #expect(image.size == NSSize(width: 16, height: 16))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        // Sample the interior away from the T and outline. Light mode must not
        // accidentally use the dark SVG's navy background again.
        let color = try #require(bitmap.colorAt(x: 4, y: 8)?.usingColorSpace(.sRGB))
        let expected: [CGFloat] = dark ? [37, 50, 77] : [245, 248, 254]
        for (actual, value) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
            #expect(abs(actual - value / 255) < 0.03)
        }
        #expect(color.alphaComponent > 0.99)
    }
}
