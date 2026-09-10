import Foundation

/// A read-only media resource presented in the editor workspace.
@MainActor
final class MediaDocument: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let kind: MediaDocumentKind

    init(url: URL, kind: MediaDocumentKind) {
        self.url = url.standardizedFileURL
        self.kind = kind
    }

    var displayName: String { url.lastPathComponent }
}

enum MediaDocumentKind: String, Sendable, Equatable {
    case image
    case video

    static func from(fileExtension: String) -> Self? {
        switch fileExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp":
            .image
        case "mp4", "mov", "m4v":
            .video
        default:
            nil
        }
    }

    static func from(url: URL) -> Self? {
        from(fileExtension: url.pathExtension)
    }
}
