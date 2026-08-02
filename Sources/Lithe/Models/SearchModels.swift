import Foundation

/// Shared search behavior for the project search sidebar and Search Everywhere.
/// Keeping the matcher here makes both surfaces agree on case, word and regex
/// semantics instead of silently returning different results.
struct ProjectSearchOptions: Hashable, Sendable {
    var caseSensitive = false
    var wholeWords = false
    var regularExpression = false

    static let `default` = ProjectSearchOptions()

    var cacheKey: String {
        [caseSensitive, wholeWords, regularExpression]
            .map { $0 ? "1" : "0" }
            .joined()
    }

    func matches(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }

        if regularExpression || wholeWords {
            let body = regularExpression
                ? query
                : "(?<![A-Za-z0-9_$])\(NSRegularExpression.escapedPattern(for: query))(?![A-Za-z0-9_$])"
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: body, options: options) else {
                return false
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return expression.firstMatch(in: text, range: range) != nil
        }

        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return text.range(of: query, options: options) != nil
    }
}
