import Foundation
import UniformTypeIdentifiers

/// Converts a paste-event snapshot without re-reading the mutable OS clipboard.
enum MonacoImagePastePayload {
    static func format(mimeType: String) throws -> MarkdownImageFormat {
        guard let type = UTType(mimeType: mimeType), type.conforms(to: .image),
              let ext = type.preferredFilenameExtension,
              let format = MarkdownImageFormat(fileExtension: ext) else {
            throw MarkdownImageImportError.couldNotReadImage
        }
        return format
    }

    static func source(base64: String, mimeType: String, filename: String?) throws -> MarkdownImageSource {
        let format = try format(mimeType: mimeType)
        // Reject oversized encoded input before allocating its decoded buffer.
        let maximumEncodedCount = ((MarkdownImageSource.maximumByteCount + 2) / 3) * 4
        guard base64.utf8.count <= maximumEncodedCount else { throw MarkdownImageImportError.imageTooLarge }
        guard let data = Data(base64Encoded: base64) else { throw MarkdownImageImportError.couldNotReadImage }
        guard !data.isEmpty else { throw MarkdownImageImportError.emptyImage }
        guard data.count <= MarkdownImageSource.maximumByteCount else { throw MarkdownImageImportError.imageTooLarge }
        return .encoded(data: data, format: format, suggestedName: filename)
    }
}
