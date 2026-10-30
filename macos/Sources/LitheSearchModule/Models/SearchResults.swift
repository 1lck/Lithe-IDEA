import Foundation

public enum SearchEverywhereProvider: String, CaseIterable, Hashable, Sendable {
    case classes = "Classes", files = "Files", symbols = "Symbols", actions = "Actions"
}

public struct FileSearchResult: Identifiable, Hashable, Sendable {
    public let kind: SearchResultKind
    public let url: URL
    public let line: Int?
    public let preview: String
    public let symbolName: String?
    public let nameMatchRanges: [SearchNameRange]
    public let matchingDegree: Int?
    public let isIgnored: Bool?

    public init(
        url: URL,
        line: Int?,
        preview: String,
        kind: SearchResultKind = .content,
        symbolName: String? = nil,
        nameMatchRanges: [SearchNameRange] = [],
        matchingDegree: Int? = nil,
        isIgnored: Bool? = nil
    ) {
        self.kind = kind
        self.url = url
        self.line = line
        self.preview = preview
        self.symbolName = symbolName
        self.nameMatchRanges = nameMatchRanges
        self.matchingDegree = matchingDegree
        self.isIgnored = isIgnored
    }

    public var id: String { "\(kind.rawValue):\(url.path):\(line ?? 0):\(preview)" }
}

/// UTF-16 ranges in the displayed name, produced by the same matcher that ranks results.
public struct SearchNameRange: Codable, Hashable, Sendable {
    public let start: Int
    public let length: Int

    public init(start: Int, length: Int) { self.start = start; self.length = length }
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
    public static let pageSize = 50
    // Legacy synchronous consumers (including Agent completion) keep bounded results.
    public static let providerLimit = 200
    public static let matchLimit = providerLimit * 4
    public let fileMatches: [FileSearchResult]
    public let classMatches: [FileSearchResult]
    public let symbolMatches: [FileSearchResult]
    public let contentMatches: [FileSearchResult]
    public let nextCursor: String?

    public init(
        fileMatches: [FileSearchResult] = [],
        classMatches: [FileSearchResult] = [],
        symbolMatches: [FileSearchResult] = [],
        contentMatches: [FileSearchResult] = [],
        nextCursor: String? = nil
    ) {
        self.fileMatches = fileMatches
        self.classMatches = classMatches
        self.symbolMatches = symbolMatches
        self.contentMatches = contentMatches
        self.nextCursor = nextCursor
    }

    public var allMatches: [FileSearchResult] {
        fileMatches + classMatches + symbolMatches + contentMatches
    }

    public var totalCount: Int { allMatches.count }
}
