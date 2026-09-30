import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Shared search field chrome", .serialized)
struct LitheSearchFieldStyleTests {
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
