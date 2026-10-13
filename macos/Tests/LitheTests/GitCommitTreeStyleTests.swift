import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Commit tree appearance", .serialized)
struct GitCommitTreeStyleTests {
    @Test func checkboxStatesResolveRealUpstreamAssetsInBothThemes() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        var paths = Set<String>()
        for state in [NSControl.StateValue.off, .on, .mixed] {
            for enabled in [true, false] {
                for focused in [true, false] {
                    let path = GitChangeInclusionCheckbox.assetPath(state: state, enabled: enabled, focused: focused)
                    for dark in [true, false] {
                        let asset = dark ? LitheIcons.darkIdeaAssetPath(for: path) : path
                        paths.insert(asset)
                        let url = resources.appendingPathComponent(asset)
                        let image = try #require(NSImage(contentsOf: url), "Missing checkbox state: \(asset)")
                        #expect(image.size == NSSize(width: 24, height: 24))
                        if enabled && !focused {
                            // Use an explicit sRGB destination so raster checks do not depend on the display profile.
                            let context = try #require(CGContext(data: nil, width: 24, height: 24,
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                            NSGraphicsContext.saveGraphicsState()
                            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                            image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
                            NSGraphicsContext.restoreGraphicsState()
                            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 3, y: bitmap.pixelsHigh / 3)?.usingColorSpace(.sRGB))
                            let expected = state == .off ? (dark ? 0x2B2D30 : 0xFFFFFF) : 0x3574F0
                            // AppKit's SVG image rep interprets literals in calibrated RGB.
                            // Compare in the same sRGB destination as the raster, not against raw components.
                            let expectedColor = try #require(NSColor(calibratedRed: CGFloat((expected >> 16) & 255) / 255,
                                green: CGFloat((expected >> 8) & 255) / 255, blue: CGFloat(expected & 255) / 255,
                                alpha: 1).usingColorSpace(.sRGB))
                            #expect(abs(color.redComponent - expectedColor.redComponent) < 0.02, "\(asset): \(color), \(expectedColor)")
                            #expect(abs(color.greenComponent - expectedColor.greenComponent) < 0.02)
                            #expect(abs(color.blueComponent - expectedColor.blueComponent) < 0.02)
                        }
                    }
                }
            }
        }
        #expect(paths.count == 18)
    }

    @Test func fileTypesUseExistingLanguageIconsInsteadOfStatusBadges() {
        #expect(LitheIcons.kind(forFilePath: "ChangesSidebarView.swift") == .swiftSource)
        #expect(LitheIcons.kind(forFilePath: "git-local-changelists.json") == .json)
        #expect(LitheIcons.kind(forFilePath: "README.md") == .markdown)
        #expect(LitheIcons.kind(forFilePath: "Localizable.strings") == .plainText)
    }
}
