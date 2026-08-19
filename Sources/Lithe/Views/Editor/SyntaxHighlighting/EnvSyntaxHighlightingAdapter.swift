import AppKit

/// Highlights dotenv assignments, interpolations, scalar values, and comments.
enum EnvSyntaxHighlightingAdapter {
    private static let numberExpression = expression(
        #"(?<![A-Za-z0-9_.-])[-+]?(?:\d[\d_]*(?:\.\d[\d_]*)?)(?![A-Za-z0-9_.-])"#
    )
    private static let booleanExpression = expression(
        #"(?<![A-Za-z0-9_.-])(?:true|false)(?![A-Za-z0-9_.-])"#,
        options: [.caseInsensitive]
    )
    private static let variableExpression = expression(#"\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"#)

    static func apply(to storage: NSTextStorage, palette: CodeEditorPalette, range target: NSRange) {
        let source = storage.string as NSString
        let scanLimit = min(NSMaxRange(target), source.length)
        var lineStart = target.location

        while lineStart < scanLimit {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentRange = lineContentRange(in: source, lineRange: lineRange)
            let trimmed = trimmedRange(in: source, range: contentRange)
            guard trimmed.length > 0 else {
                lineStart = NSMaxRange(lineRange)
                continue
            }

            if source.character(at: trimmed.location) == 35 {
                addColor(palette.comment, to: storage, range: trimmed, limitedTo: target)
                lineStart = NSMaxRange(lineRange)
                continue
            }

            let assignmentStart = assignmentStart(in: source, range: trimmed)
            guard let separator = firstAssignmentSeparator(in: source, from: assignmentStart, range: trimmed) else {
                addColor(palette.property, to: storage, range: trimmed, limitedTo: target)
                lineStart = NSMaxRange(lineRange)
                continue
            }

            let keyRange = trimmedRange(
                in: source,
                range: NSRange(location: assignmentStart, length: separator - assignmentStart)
            )
            let valueRange = trimmedRange(
                in: source,
                range: NSRange(location: separator + 1, length: NSMaxRange(trimmed) - separator - 1)
            )
            addColor(palette.property, to: storage, range: keyRange, limitedTo: target)

            let commentLocation = firstCommentLocation(in: source, range: valueRange)
            let valueBody = NSRange(
                location: valueRange.location,
                length: (commentLocation ?? NSMaxRange(valueRange)) - valueRange.location
            )
            addColor(palette.string, to: storage, range: valueBody, limitedTo: target)
            let quotedRanges = quotedStringRanges(in: source, range: valueBody)
            apply(numberExpression, color: palette.number, source: source, storage: storage, range: valueBody, excluding: quotedRanges, target: target)
            apply(booleanExpression, color: palette.keyword, source: source, storage: storage, range: valueBody, excluding: quotedRanges, target: target)
            apply(variableExpression, color: palette.annotation, source: source, storage: storage, range: valueBody, target: target)
            if let commentLocation {
                addColor(
                    palette.comment,
                    to: storage,
                    range: NSRange(location: commentLocation, length: NSMaxRange(contentRange) - commentLocation),
                    limitedTo: target
                )
            }
            lineStart = NSMaxRange(lineRange)
        }
    }

    private static func assignmentStart(in source: NSString, range: NSRange) -> Int {
        let exportPrefix = "export " as NSString
        guard range.length >= exportPrefix.length,
              source.substring(with: NSRange(location: range.location, length: exportPrefix.length)) == exportPrefix as String else {
            return range.location
        }
        return range.location + exportPrefix.length
    }

    private static func firstAssignmentSeparator(in source: NSString, from start: Int, range: NSRange) -> Int? {
        var cursor = start
        while cursor < NSMaxRange(range) {
            if source.character(at: cursor) == 61 { return cursor }
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
            if character == 92, cursor + 1 < NSMaxRange(range) {
                cursor += 2
                continue
            }
            if character == 34, !inSingleQuote { inDoubleQuote.toggle() }
            else if character == 39, !inDoubleQuote { inSingleQuote.toggle() }
            else if character == 35,
                    !inSingleQuote,
                    !inDoubleQuote,
                    (cursor == range.location || isWhitespace(source.character(at: cursor - 1))) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func quotedStringRanges(in source: NSString, range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let quote = source.character(at: cursor)
            guard quote == 34 || quote == 39 else {
                cursor += 1
                continue
            }
            let start = cursor
            cursor += 1
            while cursor < NSMaxRange(range) {
                let character = source.character(at: cursor)
                if character == 92, cursor + 1 < NSMaxRange(range) {
                    cursor += 2
                    continue
                }
                cursor += 1
                if character == quote { break }
            }
            ranges.append(NSRange(location: start, length: cursor - start))
        }
        return ranges
    }

    private static func apply(
        _ expression: NSRegularExpression,
        color: NSColor,
        source: NSString,
        storage: NSTextStorage,
        range: NSRange,
        excluding excludedRanges: [NSRange] = [],
        target: NSRange
    ) {
        expression.enumerateMatches(in: source as String, range: range) { match, _, _ in
            guard let match,
                  !excludedRanges.contains(where: { NSIntersectionRange(match.range, $0).length > 0 }) else { return }
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
