import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Git Log filter label rendering", .serialized)
struct GitLogFilterLabelTests {
    @Test(arguments: [ColorScheme.dark, .light])
    func selectedValuesKeepTheFilterNameReadableInNarrowSpace(scheme: ColorScheme) throws {
        for (title, name) in [("User", "arkleselect"), ("用户", "开发者姓名很长"),
                              ("User", "developer-with-a-very-long-name"),
                              ("Branch", "feature/very-long-branch-name"),
                              ("Paths", "src/components/very-long-file-name.swift")] {
            let prefix = title + ": "
            let font = LitheTheme.uiNSFont(size: LitheTheme.GitLog.fontSize)
            let prefixWidth = (prefix as NSString).size(withAttributes: [.font: font]).width
            let width = ceil(prefixWidth + 20)
            let actual = try render(GitLogFilterLabel(title: LocalizedStringKey(title), selection: name,
                                                     localizeSelection: false), width: width, scheme: scheme)
            let expected = try render(Text(verbatim: prefix)
                .font(LitheTheme.uiFont(size: LitheTheme.GitLog.fontSize))
                .foregroundStyle(LitheTheme.searchFieldPlaceholder).padding(4), width: width, scheme: scheme)

            // The title must stay readable before the truncated author. Separate
            // HStack text children used to compress and paint over one another.
            let prefixMatches = (0..<actual.pixelsHigh).allSatisfy { y in
                (0..<actual.pixelsWide).allSatisfy { x in
                    guard let ink = expected.colorAt(x: x, y: y), ink.alphaComponent > 0 else { return true }
                    return actual.colorAt(x: x, y: y) == ink
                }
            }
            #expect(prefixMatches, "\(title): \(name) must preserve its prefix at \(width)pt")
        }
    }

    /// Hovering a filter used to paint its name white, which disappeared against a light toolbar.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func hoveredNameStaysReadableAgainstTheToolbar(appearance name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        func luminance(_ color: Color) -> CGFloat {
            var value: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance {
                let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
                value = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            }
            return value
        }
        let surface = luminance(LitheTheme.toolHeader)
        for hovered in [false, true] {
            let ink = luminance(GitLogFilterLabel.nameColor(isHovered: hovered))
            #expect(abs(ink - surface) > 0.25, "hovered=\(hovered) \(name.rawValue)")
        }
        // Hover must emphasise the name, not fade it.
        #expect(abs(luminance(GitLogFilterLabel.nameColor(isHovered: true)) - surface)
                >= abs(luminance(GitLogFilterLabel.nameColor(isHovered: false)) - surface))
    }

    private func render<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.lineLimit(1)
            .frame(width: width, height: 28, alignment: .leading).padding(8)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }
}
