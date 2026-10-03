import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("IDEA tree row style", .serialized)
struct LitheTreeRowStyleTests {
    @Test(arguments: [ColorScheme.dark, .light], [false, true])
    func selectedRowRendersAtRegularDensityWithFocusColor(scheme: ColorScheme, focused: Bool) throws {
        let renderer = ImageRenderer(content: HStack(spacing: 2) {
            Color.clear.frame(width: 16, height: 16)
            Text("main")
            Spacer()
        }
        .litheTreeRow(isSelected: true, isFocused: focused)
        .frame(width: 220)
        .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 440)
        #expect(image.height == 48)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let expected: UInt32 = scheme == .dark
            ? (focused ? 0x2A4371 : 0x33353B)
            : (focused ? 0xD0DFFE : 0xE9EAEE)
        // Sample the row interior beyond text, so actual shared chrome rather
        // than the declared token must paint the upstream selection color.
        let offset = (24 * image.width + 300) * 4
        #expect(abs(Int(pixels[offset]) - Int((expected >> 16) & 255)) <= 2)
        #expect(abs(Int(pixels[offset + 1]) - Int((expected >> 8) & 255)) <= 2)
        #expect(abs(Int(pixels[offset + 2]) - Int(expected & 255)) <= 2)
        #expect(pixels[offset + 3] == 255)
        #expect(pixels[3] == 0) // Rounded corners retain their inset.
    }
}
