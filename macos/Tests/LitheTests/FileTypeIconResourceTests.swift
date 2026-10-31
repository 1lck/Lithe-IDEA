import AppKit
import Testing
@testable import Lithe

/// Issue #1584: every file kind that has a dedicated glyph must resolve to a
/// bundled 16pt SVG instead of falling back to the unknown-file icon.
struct FileTypeIconResourceTests {
    @Test(arguments: [
        "fileTypes/gitignore.svg",
        "fileTypes/nodejs.svg",
        "fileTypes/lock.svg",
        "fileTypes/makefile.svg",
        "fileTypes/readme.svg",
        "fileTypes/license.svg"
    ])
    func dedicatedFileGlyphIsBundled(path: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        let image = try #require(NSImage(contentsOf: root.appendingPathComponent(path)))
        #expect(image.size == NSSize(width: 16, height: 16))
    }
}
