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
    let kind: SearchResultKind
    let url: URL
    let line: Int?
    let preview: String
    let symbolName: String?

    init(
        url: URL,
        line: Int?,
        preview: String,
        kind: SearchResultKind = .content,
        symbolName: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.line = line
        self.preview = preview
        self.symbolName = symbolName
    }

    var id: String { "\(kind.rawValue):\(url.path):\(line ?? 0):\(preview)" }
}

enum SearchResultKind: String, Codable, Hashable, Sendable {
    case file
    case content
    case type
    case symbol

    var title: String {
        switch self {
        case .file: "Files"
        case .content: "Matches"
        case .type: "Classes"
        case .symbol: "Symbols"
        }
    }

    var systemImage: String {
        switch self {
        case .file: "doc.text"
        case .content: "text.magnifyingglass"
        case .type: "curlybraces.square"
        case .symbol: "function"
        }
    }
}

struct SearchSymbol: Codable, Hashable, Sendable {
    let name: String
    let kind: SearchResultKind
    let line: Int
    let signature: String
}

struct SearchEverywhereResults: Sendable {
    let fileMatches: [FileSearchResult]
    let classMatches: [FileSearchResult]
    let symbolMatches: [FileSearchResult]
    let contentMatches: [FileSearchResult]

    init(
        fileMatches: [FileSearchResult] = [],
        classMatches: [FileSearchResult] = [],
        symbolMatches: [FileSearchResult] = [],
        contentMatches: [FileSearchResult] = []
    ) {
        self.fileMatches = fileMatches
        self.classMatches = classMatches
        self.symbolMatches = symbolMatches
        self.contentMatches = contentMatches
    }

    var allMatches: [FileSearchResult] {
        fileMatches + classMatches + symbolMatches + contentMatches
    }

    var totalCount: Int { allMatches.count }
}
