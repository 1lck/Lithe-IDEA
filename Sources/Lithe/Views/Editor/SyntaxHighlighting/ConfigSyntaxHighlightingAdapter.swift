import AppKit

/// Highlights common .conf/.config sections, directives, scalar values, and comments.
enum ConfigSyntaxHighlightingAdapter {
    private static let numberExpression = expression(
        #"(?<![A-Za-z0-9_.-])[-+]?(?:0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?)(?![A-Za-z0-9_.-])"#
    )
    private static let booleanExpression = expression(
        #"(?<![A-Za-z0-9_.-])(?:true|false|yes|no|on|off|enabled|disabled)(?![A-Za-z0-9_.-])"#,
        options: [.caseInsensitive]
    )

    static func apply(to storage: NSTextStorage, palette: CodeEditorPalette, range target: NSRange) {
        let source = storage.string as NSString
        let scanLimit = min(NSMaxRange(target), source.length)
        var lineStart = target.location

        while lineStart < scanLimit {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentRange = lineContentRange(in: source, lineRange: lineRange)
            let commentLocation = firstCommentLocation(in: source, range: contentRange)
            let bodyRange = NSRange(location: contentRange.location, length: (commentLocation ?? NSMaxRange(contentRange)) - contentRange.location)
            let trimmedBody = trimmedRange(in: source, range: bodyRange)

            if let sectionRange = sectionRange(in: source, range: trimmedBody) {
                addColor(palette.type, to: storage, range: sectionRange, limitedTo: target)
            } else if let separator = separatorLocation(in: source, range: trimmedBody) {
                let keyRange = trimmedRange(in: source, range: NSRange(location: trimmedBody.location, length: separator - trimmedBody.location))
                let valueStart = skipSeparators(in: source, from: separator + 1, limit: NSMaxRange(trimmedBody))
                let valueRange = NSRange(location: valueStart, length: NSMaxRange(trimmedBody) - valueStart)
                addColor(palette.property, to: storage, range: keyRange, limitedTo: target)
                addColor(palette.string, to: storage, range: valueRange, limitedTo: target)
                let quotedRanges = quotedStringRanges(in: source, range: valueRange)
                apply(numberExpression, color: palette.number, source: source, storage: storage, range: valueRange, excluding: quotedRanges, target: target)
                apply(booleanExpression, color: palette.keyword, source: source, storage: storage, range: valueRange, excluding: quotedRanges, target: target)
            }

            if let commentLocation {
                addColor(palette.comment, to: storage, range: NSRange(location: commentLocation, length: NSMaxRange(contentRange) - commentLocation), limitedTo: target)
            }
            lineStart = NSMaxRange(lineRange)
        }
    }

    private static func sectionRange(in source: NSString, range: NSRange) -> NSRange? {
        guard range.length >= 2,
              source.character(at: range.location) == 91,
              source.character(at: NSMaxRange(range) - 1) == 93 else { return nil }
        return range
    }

    private static func separatorLocation(in source: NSString, range: NSRange) -> Int? {
        var cursor = range.location
        var sawKeyCharacter = false
        var inSingleQuote = false
        var inDoubleQuote = false
        while cursor < NSMaxRange(range) {
            let character = source.character(at: cursor)
            if character == 92, inDoubleQuote, cursor + 1 < NSMaxRange(range) { cursor += 2; continue }
            if character == 34, !inSingleQuote { inDoubleQuote.toggle() }
            else if character == 39, !inDoubleQuote { inSingleQuote.toggle() }
            else if !inSingleQuote, !inDoubleQuote, character == 61 || character == 58 { return cursor }
            else if !inSingleQuote, !inDoubleQuote, isWhitespace(character), sawKeyCharacter { return cursor }
            else if !isWhitespace(character) { sawKeyCharacter = true }
            cursor += 1
        }
        return nil
    }

    private static func firstCommentLocation(in source: NSString, range: NSRange) -> Int? {
        var cursor = range.location
        var inSingleQuote = false
        var inDoubleQuote = false
        while cursor < NSMaxRange(range) {
            let character = source.character(at: cursor)
            if character == 92, inDoubleQuote, cursor + 1 < NSMaxRange(range) { cursor += 2; continue }
            if character == 34, !inSingleQuote { inDoubleQuote.toggle() }
            else if character == 39, !inDoubleQuote { inSingleQuote.toggle() }
            else if (character == 35 || character == 59), !inSingleQuote, !inDoubleQuote,
                    (cursor == range.location || isWhitespace(source.character(at: cursor - 1))) { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func skipSeparators(in source: NSString, from start: Int, limit: Int) -> Int {
        var cursor = start
        while cursor < limit, isWhitespace(source.character(at: cursor)) { cursor += 1 }
        return cursor
    }

    private static func quotedStringRanges(in source: NSString, range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let quote = source.character(at: cursor)
            guard quote == 34 || quote == 39 else { cursor += 1; continue }
            let start = cursor
            cursor += 1
            while cursor < NSMaxRange(range) {
                let character = source.character(at: cursor)
                if character == 92, quote == 34, cursor + 1 < NSMaxRange(range) { cursor += 2; continue }
                cursor += 1
                if character == quote { break }
            }
            ranges.append(NSRange(location: start, length: cursor - start))
        }
        return ranges
    }

    private static func apply(_ expression: NSRegularExpression, color: NSColor, source: NSString, storage: NSTextStorage, range: NSRange, excluding excludedRanges: [NSRange], target: NSRange) {
        expression.enumerateMatches(in: source as String, range: range) { match, _, _ in
            guard let match, !excludedRanges.contains(where: { NSIntersectionRange(match.range, $0).length > 0 }) else { return }
            addColor(color, to: storage, range: match.range, limitedTo: target)
        }
    }

    private static func addColor(_ color: NSColor, to storage: NSTextStorage, range: NSRange, limitedTo target: NSRange) {
        let affectedRange = NSIntersectionRange(range, target)
        guard affectedRange.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: affectedRange)
    }

    private static func lineContentRange(in source: NSString, lineRange: NSRange) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location, [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private static func trimmedRange(in source: NSString, range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(source.character(at: start)) { start += 1 }
        while end > start, isWhitespace(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ character: unichar) -> Bool { character == 32 || character == 9 }

    private static func expression(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
