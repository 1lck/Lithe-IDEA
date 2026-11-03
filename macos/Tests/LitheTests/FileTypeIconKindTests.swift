import AppKit
import Testing
@testable import Lithe

@MainActor
struct FileTypeIconKindTests {
    @Test(arguments: ["a.jsonl", "a.jsonlines", "a.ndjson", "a.ldjson"])
    func jsonLinesUseJsonIcon(fileName: String) {
        #expect(LitheIcons.kind(forFilePath: "/fixture/\(fileName)") == .json)
    }

    @Test
    func wbmpUsesImageIcon() {
        #expect(LitheIcons.kind(forFilePath: "/fixture/a.wbmp") == .image)
    }

    @Test(arguments: ["a.doc", "a.docx", "a.ppt", "a.pptx"])
    func officeDocumentsUseNativeFileIcon(fileName: String) {
        #expect(LitheIcons.kind(forFilePath: "/fixture/\(fileName)") == .document)
    }

    @Test
    func stringsFilesUseI18nIcon() {
        #expect(LitheIcons.kind(forFilePath: "/fixture/Localizable.strings") == .i18n)
    }

    @Test(arguments: [LitheIconKind.document, .i18n])
    func newKindsShipLightAndDarkAssets(kind: LitheIconKind) throws {
        // The unit-test host ships no app bundle, so resolve the catalog entry
        // and load the source assets directly instead of calling ideaImage.
        let assetPath = try #require(LitheIcons.ideaAssetPath(for: kind))
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for path in [assetPath, LitheIcons.darkIdeaAssetPath(for: assetPath)] {
            let image = try #require(NSImage(contentsOf: resources.appendingPathComponent(path)),
                "Missing IDEA icon asset: \(path)")
            #expect(image.size.width > 0)
        }
    }
}
