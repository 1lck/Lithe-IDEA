import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("IDEA tree row style", .serialized)
struct LitheTreeRowStyleTests {
    // SwiftUI on macOS 26 normalizes an injected .active to .key; key/inactive are distinct rendered states.
    @Test(arguments: [ColorScheme.dark, .light], [ControlActiveState.key, .inactive])
    func selectedRowsHonorRegionAndWindowFocus(scheme: ColorScheme, windowState: ControlActiveState) throws {
        for focused in [false, true] {
            for tree in [false, true] {
                let row = HStack(spacing: 2) {
                    Color.clear.frame(width: 16, height: 16)
                    Text("main")
                    Spacer()
                }
                let content = tree
                    ? AnyView(row.litheTreeRow(isSelected: true, isFocused: focused))
                    : AnyView(row.frame(height: 40).litheSelectionRow(isSelected: true, isFocused: focused))
                let renderer = ImageRenderer(content: content.frame(width: 220)
                    .environment(\.colorScheme, scheme)
                    .environment(\.controlActiveState, windowState))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == 440)
                #expect(image.height == (tree ? 48 : 80))
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                try pixels.withUnsafeMutableBytes { bytes in
                    let context = try #require(CGContext(
                        data: bytes.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let active = focused && windowState == .key
                let expected: UInt32 = scheme == .dark
                    ? (active ? 0x2A4371 : 0x33353B)
                    : (active ? 0xD0DFFE : 0xE9EAEE)
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
    }
}
