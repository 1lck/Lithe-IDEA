import Foundation

struct ProjectReplacementMatch: Identifiable, Hashable, Sendable {
    let line: Int
    let before: String
    let after: String
    let occurrenceCount: Int

    var id: String { "\(line):\(before):\(after)" }
}

struct ProjectReplacementFile: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    let matches: [ProjectReplacementMatch]
    let replacementText: String?

    init(
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

    var id: String { url.path }
    var matchCount: Int { matches.reduce(0) { $0 + $1.occurrenceCount } }
}
