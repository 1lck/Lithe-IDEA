import Foundation

public struct ProjectReplacementMatch: Identifiable, Hashable, Sendable {
    public let line: Int
    public let before: String
    public let after: String
    public let occurrenceCount: Int

    public init(line: Int, before: String, after: String, occurrenceCount: Int) {
        self.line = line
        self.before = before
        self.after = after
        self.occurrenceCount = occurrenceCount
    }

    public var id: String { "\(line):\(before):\(after)" }
}

public struct ProjectReplacementFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let relativePath: String
    public let matches: [ProjectReplacementMatch]
    public let replacementText: String?

    public init(
        url: URL,
        relativePath: String,
        matches: [ProjectReplacementMatch],
        replacementText: String? = nil
    ) {
        self.url = url
        self.relativePath = relativePath
        self.matches = matches
        self.replacementText = replacementText
    }

    public var id: String { url.path }
    public var matchCount: Int { matches.reduce(0) { $0 + $1.occurrenceCount } }
}
