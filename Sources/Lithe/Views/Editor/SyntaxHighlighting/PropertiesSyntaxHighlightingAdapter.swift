import AppKit

/// Highlights Java properties keys, values, continuations, and line comments.
enum PropertiesSyntaxHighlightingAdapter {
    private static let numberExpression = expression(
        #"(?<![A-Za-z0-9_.-])[-+]?(?:\d[\d_]*(?:\.\d[\d_]*)?)(?![A-Za-z0-9_.-])"#
    )
    private static let booleanExpression = expression(
        #"(?<![A-Za-z0-9_.-])(?:true|false)(?![A-Za-z0-9_.-])"#,
        options: [.caseInsensitive]
    )

    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range target: NSRange) {
        let source = storage.string as NSString
        let scanLimit = min(NSMaxRange(target), source.length)
        var lineStart = logicalStart(for: target.location, in: source)
        var continuation = false

        while lineStart < source.length && (lineStart < scanLimit || continuation) {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentRange = lineContentRange(in: source, lineRange: lineRange)
            let trimmed = trimmedRange(in: source, range: contentRange)
            let highlightRange = NSMaxRange(lineRange) > target.location
                ? lineRange
                : NSRange(location: target.location, length: 0)
            if highlightRange.length > 0 {
                // Continuation changes can propagate past the dirty range, so
                // reset each affected line before applying its current tokens.
                storage.addAttribute(.foregroundColor, value: palette.text, range: lineRange)
            }
            guard trimmed.length > 0 else {
                continuation = false
                lineStart = NSMaxRange(lineRange)
                continue
            }

            if continuation {
                addColor(palette.string, to: storage, range: trimmed, limitedTo: highlightRange)
                continuation = endsWithContinuation(in: source, range: contentRange)
                lineStart = NSMaxRange(lineRange)
                continue
            }
            let first = source.character(at: trimmed.location)
            if first == 35 || first == 33 {
                addColor(palette.comment, to: storage, range: trimmed, limitedTo: highlightRange)
                lineStart = NSMaxRange(lineRange)
                continue
            }

            if let separator = separatorLocation(in: source, range: trimmed) {
                let keyRange = trimmedRange(in: source, range: NSRange(location: trimmed.location, length: separator - trimmed.location))
                let valueStart = valueStart(in: source, after: separator, limit: NSMaxRange(trimmed))
                let valueRange = NSRange(location: valueStart, length: NSMaxRange(trimmed) - valueStart)
                addColor(palette.property, to: storage, range: keyRange, limitedTo: highlightRange)
                addColor(palette.string, to: storage, range: valueRange, limitedTo: highlightRange)
                let quotedRanges = quotedStringRanges(in: source, range: valueRange)
                apply(numberExpression, color: palette.number, source: source, storage: storage, range: valueRange, excluding: quotedRanges, target: highlightRange)
                apply(booleanExpression, color: palette.keyword, source: source, storage: storage, range: valueRange, excluding: quotedRanges, target: highlightRange)
                continuation = endsWithContinuation(in: source, range: contentRange)
            } else {
                addColor(palette.property, to: storage, range: trimmed, limitedTo: highlightRange)
                continuation = false
            }
            lineStart = NSMaxRange(lineRange)
        }
    }

    private static func logicalStart(for location: Int, in source: NSString) -> Int {
        var lineStart = source.lineRange(
            for: NSRange(location: min(max(0, location), max(0, source.length - 1)), length: 0)
        ).location
        while lineStart > 0 {
            let previousLine = source.lineRange(for: NSRange(location: lineStart - 1, length: 0))
            let previousContent = lineContentRange(in: source, lineRange: previousLine)
            guard endsWithContinuation(in: source, range: previousContent) else { break }
            lineStart = previousLine.location
        }
        return lineStart
    }

    private static func separatorLocation(in source: NSString, range: NSRange) -> Int? {
        var cursor = range.location
        var sawKeyCharacter = false
        while cursor < NSMaxRange(range) {
            let character = source.character(at: cursor)
            if character == 92, cursor + 1 < NSMaxRange(range) { cursor += 2; sawKeyCharacter = true; continue }
            if character == 61 || character == 58 { return cursor }
            if isWhitespace(character), sawKeyCharacter { return cursor }
            if !isWhitespace(character) { sawKeyCharacter = true }
            cursor += 1
        }
        return nil
    }

    private static func valueStart(in source: NSString, after separator: Int, limit: Int) -> Int {
        var cursor = separator
        if cursor < limit, source.character(at: cursor) == 61 || source.character(at: cursor) == 58 {
            cursor += 1
        }
        while cursor < limit, isWhitespace(source.character(at: cursor)) { cursor += 1 }
        if cursor < limit, source.character(at: cursor) == 61 || source.character(at: cursor) == 58 {
            cursor += 1
        }
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
                if character == 92, cursor + 1 < NSMaxRange(range) { cursor += 2; continue }
                cursor += 1
                if character == quote { break }
            }
            ranges.append(NSRange(location: start, length: cursor - start))
        }
        return ranges
    }

    private static func endsWithContinuation(in source: NSString, range: NSRange) -> Bool {
        var cursor = NSMaxRange(range) - 1
        guard cursor >= range.location, source.character(at: cursor) == 92 else { return false }
        var backslashes = 0
        while cursor >= range.location, source.character(at: cursor) == 92 { backslashes += 1; cursor -= 1 }
        return backslashes % 2 == 1
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
