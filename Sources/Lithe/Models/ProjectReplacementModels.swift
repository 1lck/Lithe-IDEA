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

    var id: String { url.path }
    var matchCount: Int { matches.reduce(0) { $0 + $1.occurrenceCount } }
}

private extension String {
    func countOccurrences(of query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = range(of: query, options: [.caseInsensitive], range: searchStart..<endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}

enum ProjectReplacementEngine {
    static func preview(text: String, query: String, replacement: String) -> [ProjectReplacementMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [ProjectReplacementMatch] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, enclosingRange, _ in
            guard let line,
                  line.range(of: query, options: [.caseInsensitive]) != nil else { return }
            matches.append(ProjectReplacementMatch(
                line: lineNumber(at: enclosingRange.lowerBound, in: text),
                before: line,
                after: replace(in: line, query: query, replacement: replacement),
                occurrenceCount: line.countOccurrences(of: query)
            ))
        }
        return matches
    }

    static func replace(in text: String, query: String, replacement: String) -> String {
        guard !query.isEmpty else { return text }
        let mutableText = NSMutableString(string: text)
        mutableText.replaceOccurrences(
            of: query,
            with: replacement,
            options: [.caseInsensitive],
            range: NSRange(location: 0, length: mutableText.length)
        )
        return mutableText as String
    }

    private static func lineNumber(at index: String.Index, in text: String) -> Int {
        text[..<index].reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }
}
