import Foundation

enum MarkdownImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case gif
    case webp
    case heic
    case heif
    case tiff
    case bmp
    case svg
    case avif
    case ico

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "gif": self = .gif
        case "webp": self = .webp
        case "heic": self = .heic
        case "heif": self = .heif
        case "tif", "tiff": self = .tiff
        case "bmp": self = .bmp
        case "svg": self = .svg
        case "avif": self = .avif
        case "ico": self = .ico
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }
}

enum MarkdownImageSource: Sendable {
    case encoded(data: Data, format: MarkdownImageFormat, suggestedName: String?)
    case file(url: URL, format: MarkdownImageFormat)
}

struct MarkdownImageImportResult: Equatable, Sendable {
    let fileURL: URL
    let relativePath: String
    let markdownReference: String
}

protocol MarkdownImageImporting: Sendable {
    func importImage(
        _ source: MarkdownImageSource,
        forDocumentAt documentURL: URL,
        workspaceRoot: URL
    ) async throws -> MarkdownImageImportResult
}

enum MarkdownImageImportError: LocalizedError, Equatable, Sendable {
    case unavailableWorkspace
    case readOnlyDocument
    case notMarkdownDocument
    case destinationOutsideWorkspace
    case invalidAssetDirectory
    case emptyImage
    case imageTooLarge
    case couldNotReadImage
    case couldNotChooseFilename

    var errorDescription: String? {
        switch self {
        case .unavailableWorkspace:
            "Open the Markdown file inside a workspace before pasting an image"
        case .readOnlyDocument:
            "This Markdown document is read-only"
        case .notMarkdownDocument:
            "Images can only be pasted into Markdown documents"
        case .destinationOutsideWorkspace:
            "The image destination is outside the current workspace"
        case .invalidAssetDirectory:
            "The Markdown assets path is not a writable directory"
        case .emptyImage:
            "The clipboard image is empty"
        case .imageTooLarge:
            "The clipboard image is larger than 100 MB"
        case .couldNotReadImage:
            "The clipboard image could not be read"
        case .couldNotChooseFilename:
            "A unique filename could not be created for the image"
        }
    }
}
