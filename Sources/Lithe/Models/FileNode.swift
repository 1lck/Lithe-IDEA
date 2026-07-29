import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let children: [FileNode]?

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var systemImage: String {
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "java", "kt", "kts": return "cup.and.saucer"
        case "js", "jsx", "ts", "tsx": return "curlybraces"
        case "json", "yml", "yaml", "xml", "toml": return "slider.horizontal.3"
        case "md", "txt", "rst": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        default: return "doc"
        }
    }
}

struct WorkspaceSnapshot: Sendable {
    let root: FileNode
    let files: [URL]
}

struct FileSearchResult: Identifiable, Hashable, Sendable {
    let url: URL
    let line: Int?
    let preview: String

    var id: String { "\(url.path):\(line ?? 0):\(preview)" }
}
