import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("IDEA test source tab colors", .serialized)
struct EditorTabColorTests {
    @Test(arguments: [ColorScheme.dark, .light], [ControlActiveState.key, .inactive])
    func selectedTestTabPaintsInsetScopeColor(scheme: ColorScheme, window: ControlActiveState) throws {
        let renderer = ImageRenderer(content: Color.clear.frame(width: 180, height: 28)
            .modifier(LitheToolWindowTabStyle(isSelected: true, isActive: true,
                fileColor: LitheToolWindowTabStyle.testSourceColor(for: scheme)))
            .environment(\.colorScheme, scheme).environment(\.controlActiveState, window))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let inside = (14 * image.width + 90) * 4
        let outside = (2 * image.width + 90) * 4
        let green: [CGFloat] = scheme == .dark ? [28, 38, 28] : [237, 250, 239]
        let opacity: CGFloat = window == .key ? 1 : 0.4
        let actual = (0..<3).map { CGFloat(pixels[inside + $0]) / 255 }
        let surface = (0..<3).map { CGFloat(pixels[outside + $0]) / 255 }
        for channel in 0..<3 {
            #expect(abs(actual[channel] - (green[channel] / 255 * opacity + surface[channel] * (1 - opacity))) < 0.015)
        }
        #expect(abs(actual[1] - surface[1]) > 0.002)
    }
}
