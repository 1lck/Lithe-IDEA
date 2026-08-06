import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let children: [FileNode]?
    /// 被压缩的中间包所对应的目录（不含本节点自身）。展开/折叠时需要
    /// 一并处理，否则父目录的展开状态会和显示的行对不上。
    let collapsedAncestorPaths: [String]
    /// 该目录是否位于源码根之下，决定用包图标还是普通文件夹图标。
    let isInsideSourceRoot: Bool

    init(
        url: URL,
        isDirectory: Bool,
        children: [FileNode]?,
        collapsedAncestorPaths: [String] = [],
        isInsideSourceRoot: Bool = false
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
        self.collapsedAncestorPaths = collapsedAncestorPaths
        self.isInsideSourceRoot = isInsideSourceRoot
    }

    var id: String { url.path }

    /// 压缩中间包后显示的名字，例如 com.alibaba.nacos.ai。
    var name: String {
        guard !collapsedAncestorPaths.isEmpty else { return url.lastPathComponent }
        let names = collapsedAncestorPaths.map { ($0 as NSString).lastPathComponent }
        return (names + [url.lastPathComponent]).joined(separator: ".")
    }

    var iconKind: LitheIconKind {
        LitheIcons.kind(for: url, isDirectory: isDirectory, isInsideSourceRoot: isInsideSourceRoot)
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
}

struct SearchSymbol: Codable, Hashable, Sendable {
    let name: String
    let kind: SearchResultKind
    let line: Int
    let signature: String
}

struct SearchEverywhereResults: @unchecked Sendable {
    /// 后端一次最多返回这么多命中；命中数顶到上限时 UI 提示还有更多。
    static let matchLimit = 200

    let fileMatches: [FileSearchResult]
    let classMatches: [FileSearchResult]
    let symbolMatches: [FileSearchResult]
    let contentMatches: [FileSearchResult]
    let actionMatches: [LitheAction]

    init(
        fileMatches: [FileSearchResult] = [],
        classMatches: [FileSearchResult] = [],
        symbolMatches: [FileSearchResult] = [],
        contentMatches: [FileSearchResult] = [],
        actionMatches: [LitheAction] = []
    ) {
        self.fileMatches = fileMatches
        self.classMatches = classMatches
        self.symbolMatches = symbolMatches
        self.contentMatches = contentMatches
        self.actionMatches = actionMatches
    }

    var allMatches: [FileSearchResult] {
        fileMatches + classMatches + symbolMatches + contentMatches
    }

    var totalCount: Int { allMatches.count + actionMatches.count }
}
