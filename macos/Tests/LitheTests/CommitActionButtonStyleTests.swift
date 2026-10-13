import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Commit action button chrome", .serialized)
struct CommitActionButtonStyleTests {
    @Test(arguments: [ColorScheme.dark, .light], [
        (primary: false, enabled: false), (primary: false, enabled: true),
        (primary: true, enabled: false), (primary: true, enabled: true)
    ])
    func buttonReservesIDEABorderInsetsAndRendersEnabledAndDisabledColors(
        scheme: ColorScheme, state: (primary: Bool, enabled: Bool)
    ) throws {
        let (primary, enabled) = state
        let renderer = ImageRenderer(content: Button {} label: {
            Color.clear.frame(width: 10, height: 12)
        }
        .buttonStyle(CommitActionButtonStyle(isPrimary: primary))
        .disabled(!enabled)
        .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 156) // 72pt visible width + 3pt on each side.
        #expect(image.height == 68) // 28pt visible height + 3pt on each side.
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
            let offset = (y * image.width + x) * 4
            return pixels[offset..<(offset + 4)]
        }
        #expect(pixel(5, 34).last == 0)
        #expect(pixel(6, 6).last! < 25) // 4pt rounded corner, not a square.
        let border: UInt32 = enabled ? (primary ? 0x3871E1 : (scheme == .dark ? 0x40434A : 0xD1D3D9))
                                    : (scheme == .dark ? 0x33353B : 0xDDDFE4)
        let expected = [UInt8((border >> 16) & 255), UInt8((border >> 8) & 255), UInt8(border & 255), 255]
        #expect(zip(pixel(6, 34), expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
        if enabled && primary {
            #expect(zip(pixel(30, 34), [0x38, 0x71, 0xE1, 255]).allSatisfy { abs(Int($0) - $1) <= 2 })
        } else if enabled && scheme == .light {
            #expect(pixel(30, 34).allSatisfy { $0 == 255 })
        } else {
            #expect(pixel(30, 34).last == 0)
        }
    }
}
