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
    func newKindsShipLightAndDarkAssets(kind: LitheIconKind) {
        #expect(LitheIcons.ideaImage(for: kind) != nil)
        #expect(LitheIcons.ideaImage(for: kind, isDark: true) != nil)
    }
}
