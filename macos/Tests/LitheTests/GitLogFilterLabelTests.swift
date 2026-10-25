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

    private func render<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.lineLimit(1)
            .frame(width: width, height: 28, alignment: .leading).padding(8)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }
}
