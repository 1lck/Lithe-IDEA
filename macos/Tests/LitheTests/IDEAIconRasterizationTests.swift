import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct IDEAIconRasterizationTests {
    @Test(arguments: ["chevronRight", "chevronDown", "expandAll", "collapseAll"], [false, true])
    func originalArrowEdgesRemainSymmetricAtNativeScales(name: String, dark: Bool) throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons/expui/general")
        let source = try #require(NSImage(contentsOf: resources.appendingPathComponent("\(name)\(dark ? "_dark" : "").svg")))
        let image = LitheIcons.antialiasedIDEAImage(source)
        #expect(image.size == source.size)
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16))
            renderer.scale = scale
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            var coverage: CGFloat = 0
            var asymmetry: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let alpha = try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
                    let reflected = try #require(bitmap.colorAt(
                        x: name == "chevronRight" ? x : bitmap.pixelsWide - 1 - x,
                        y: name == "chevronRight" ? bitmap.pixelsHigh - 1 - y : y
                    )).alphaComponent
                    coverage += alpha
                    asymmetry = max(asymmetry, abs(alpha - reflected))
                }
            }
            #expect(coverage > 4, "The real SVG must be visible")
            // Direct CoreSVG 1x rendering drops coverage from one endpoint of
            // chevronRight. This protects the geometry, not a particular color profile.
            #expect(asymmetry < 0.02, "\(name) at \(scale)x has asymmetric edge coverage: \(asymmetry)")
        }
    }
}
