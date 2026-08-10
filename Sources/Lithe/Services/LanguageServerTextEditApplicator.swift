import Foundation

enum LanguageServerTextEditApplicator {
    enum Error: LocalizedError, Equatable {
        case invalidRange
        case overlappingEdits

        var errorDescription: String? {
            switch self {
            case .invalidRange: "Language server returned an invalid text range."
            case .overlappingEdits: "Language server returned overlapping text edits."
            }
        }
    }

    static func apply(_ edits: [LanguageServerTextEdit], to text: String) throws -> String {
        let source = text as NSString
        var replacements: [(NSRange, String)] = []
        for edit in edits {
            guard let start = utf16Offset(edit.range.start, in: source),
                  let end = utf16Offset(edit.range.end, in: source),
                  end >= start else { throw Error.invalidRange }
            replacements.append((NSRange(location: start, length: end - start), edit.newText))
        }
        replacements.sort { $0.0.location > $1.0.location }
        for index in 0..<max(0, replacements.count - 1) {
            guard NSMaxRange(replacements[index + 1].0) <= replacements[index].0.location else {
                throw Error.overlappingEdits
            }
        }
        let mutable = NSMutableString(string: text)
        for (range, replacement) in replacements {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    private static func utf16Offset(
        _ position: LanguageServerPosition,
        in source: NSString
    ) -> Int? {
        guard position.line >= 0, position.utf16Column >= 0 else { return nil }
        var line = 0
        var cursor = 0
        while cursor < source.length, line < position.line {
            var lineEnd = 0
            source.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: cursor, length: 0))
            guard lineEnd > cursor else { return nil }
            cursor = lineEnd
            line += 1
        }
        guard line == position.line, cursor <= source.length else { return nil }
        var lineEnd = source.length
        var contentsEnd = source.length
        source.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
        return cursor + min(position.utf16Column, max(0, contentsEnd - cursor))
    }
}

enum LanguageServerSnippet {
    static func plainText(_ value: String) -> String {
        var result = value
        if let placeholders = try? NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#) {
            result = placeholders.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "$1"
            )
        }
        if let tabStops = try? NSRegularExpression(pattern: #"\$\{?\d+\}?"#) {
            result = tabStops.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
        }
        return result
    }
}
