import Foundation

public struct FileSearchResult: Identifiable, Hashable, Sendable {
    public let kind: SearchResultKind
    public let url: URL
    public let line: Int?
    public let preview: String
    public let symbolName: String?

    public init(
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

    public var id: String { "\(kind.rawValue):\(url.path):\(line ?? 0):\(preview)" }
}

public enum SearchResultKind: String, Codable, Hashable, Sendable {
    case file
    case content
    case type
    case symbol

    public var title: String {
        switch self {
        case .file: "Files"
        case .content: "Matches"
        case .type: "Classes"
        case .symbol: "Symbols"
        }
    }
}

public struct SearchSymbol: Codable, Hashable, Sendable {
    public let name: String
    public let kind: SearchResultKind
    public let line: Int
    public let signature: String

    public init(name: String, kind: SearchResultKind, line: Int, signature: String) {
        self.name = name
        self.kind = kind
        self.line = line
        self.signature = signature
    }
}

public struct SearchEverywhereResults: Sendable {
    public static let matchLimit = 200
    public let fileMatches: [FileSearchResult]
    public let classMatches: [FileSearchResult]
    public let symbolMatches: [FileSearchResult]
    public let contentMatches: [FileSearchResult]

    public init(
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

    public var allMatches: [FileSearchResult] {
        fileMatches + classMatches + symbolMatches + contentMatches
    }

    public var totalCount: Int { allMatches.count }
}
