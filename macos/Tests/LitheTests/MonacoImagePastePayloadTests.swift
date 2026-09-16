import Foundation
import Testing
@testable import Lithe

@Suite("Monaco image paste payload")
struct MonacoImagePastePayloadTests {
    @Test func snapshotPreservesBytesAndFilename() throws {
        let bytes = Data([0, 1, 128, 255])
        let source = try MonacoImagePastePayload.source(base64: bytes.base64EncodedString(),
            mimeType: "image/png", filename: "screen.png")
        guard case .encoded(let actual, let format, let name) = source else {
            Issue.record("Paste snapshot became a mutable clipboard or file reference")
            return
        }
        #expect(actual == bytes)
        #expect(format == .png)
        #expect(name == "screen.png")
    }

    @Test(arguments: [("image/jpeg", MarkdownImageFormat.jpeg), ("image/svg+xml", .svg), ("image/tiff", .tiff)])
    func browserMIMETypesResolveToSupportedFormats(mime: String, expected: MarkdownImageFormat) throws {
        #expect(try MonacoImagePastePayload.format(mimeType: mime) == expected)
    }

    @Test func malformedAndNonImagePayloadsAreRejected() {
        #expect(throws: MarkdownImageImportError.couldNotReadImage) {
            try MonacoImagePastePayload.source(base64: "not base64!", mimeType: "image/png", filename: nil)
        }
        #expect(throws: MarkdownImageImportError.emptyImage) {
            try MonacoImagePastePayload.source(base64: "", mimeType: "image/png", filename: nil)
        }
        #expect(throws: MarkdownImageImportError.couldNotReadImage) {
            try MonacoImagePastePayload.source(base64: "dGV4dA==", mimeType: "text/plain", filename: "fake.png")
        }
    }
}
