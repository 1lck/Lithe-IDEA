import AppKit

/// Highlights TOML tables, assignments, scalar values, comments, and multiline strings.
enum TOMLSyntaxHighlightingAdapter {
    /// Lexer state cached after a physical line; `nil` means normal TOML content.
    private struct CachedMultilineState {
        let delimiter: String?
    }

    private static let multilineStateAttribute = NSAttributedString.Key("lithe.toml.multiline-state")
    private static let numberExpression = expression(
        #"(?<![A-Za-z0-9_.-])[-+]?(?:0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?|inf|nan)(?![A-Za-z0-9_.-])"#,
        options: [.caseInsensitive]
    )
    private static let dateExpression = expression(
        #"\b\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[-+]\d{2}:\d{2})?)?\b|\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b"#
    )
    private static let booleanExpression = expression(
        #"(?<![A-Za-z0-9_.-])(?:true|false)(?![A-Za-z0-9_.-])"#,
        options: [.caseInsensitive]
    )
    private static let inlinePropertyExpression = expression(
        #"(?:[,{])[ \t]*([A-Za-z0-9_-]+|\"(?:\\.|[^\"\\])*\"|'[^']*')(?=[ \t]*=)"#
    )

    @discardableResult
    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range target: NSRange) -> Int {
        let source = storage.string as NSString
        guard source.length > 0 else { return 0 }
        let scanStart = lineRange(containing: target.location, in: source).location
        let requiredEnd = NSMaxRange(lineRange(containing: max(target.location, NSMaxRange(target) - 1), in: source))
        let cachedStateBeforeTarget = cachedMultilineState(at: scanStart - 1, in: storage)
        let shouldConverge = cachedStateBeforeTarget != nil
            || cachedMultilineState(afterLineEndingAt: requiredEnd, in: storage) != nil
        var multilineDelimiter = cachedStateBeforeTarget?.delimiter
        var scannedLineCount = 0

        // Line-ending attributes move with NSTextStorage edits, so an unchanged
        // predecessor restores state in O(1) and rescanning stops after convergence.
        if cachedStateBeforeTarget == nil, scanStart > 0 {
            var prefixLineStart = 0
            while prefixLineStart < scanStart {
                let lineRange = source.lineRange(for: NSRange(location: prefixLineStart, length: 0))
                updateMultilineState(
                    in: lineRange,
                    source: source,
                    multilineDelimiter: &multilineDelimiter
                )
                cache(multilineDelimiter: multilineDelimiter, after: lineRange, in: storage)
                prefixLineStart = NSMaxRange(lineRange)
                scannedLineCount += 1
            }
        }

        storage.removeAttribute(
            multilineStateAttribute,
            range: NSRange(location: scanStart, length: max(0, requiredEnd - scanStart))
        )

        var lineStart = scanStart
        while lineStart < source.length {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let cachedExitState = cachedMultilineState(after: lineRange, in: storage)
            let contentRange = lineContentRange(in: source, lineRange: lineRange)
            storage.addAttribute(.foregroundColor, value: palette.text, range: lineRange)

            if let activeMultilineDelimiter = multilineDelimiter {
                if let closingRange = stringClosingRange(
                    delimiterCharacter: activeMultilineDelimiter == "\"\"\"" ? 34 : 39,
                    isMultiline: true,
                    in: source,
                    from: contentRange.location,
                    limit: NSMaxRange(contentRange)
                ) {
                    addColor(
                        palette.string,
                        to: storage,
                        range: NSRange(
                            location: contentRange.location,
                            length: NSMaxRange(closingRange) - contentRange.location
                        ),
                        limitedTo: lineRange
                    )
                    let remainder = NSRange(
                        location: NSMaxRange(closingRange),
                        length: NSMaxRange(contentRange) - NSMaxRange(closingRange)
                    )
                    if let commentLocation = firstCommentLocation(in: source, range: remainder) {
                        addColor(
                            palette.comment,
                            to: storage,
                            range: NSRange(location: commentLocation, length: NSMaxRange(contentRange) - commentLocation),
                            limitedTo: lineRange
                        )
                    }
                    multilineDelimiter = nil
                } else {
                    addColor(palette.string, to: storage, range: contentRange, limitedTo: lineRange)
                }
                cache(multilineDelimiter: multilineDelimiter, after: lineRange, in: storage)
                scannedLineCount += 1
                lineStart = NSMaxRange(lineRange)
                if shouldStop(
                    after: lineRange,
                    requiredEnd: requiredEnd,
                    shouldConverge: shouldConverge,
                    cachedExitState: cachedExitState,
                    multilineDelimiter: multilineDelimiter
                ) {
                    break
                }
                continue
            }

            let commentLocation = firstCommentLocation(in: source, range: contentRange)
            let bodyRange = NSRange(
                location: contentRange.location,
                length: (commentLocation ?? NSMaxRange(contentRange)) - contentRange.location
            )

            if let tableRange = tableHeaderRange(in: source, range: bodyRange) {
                addColor(palette.type, to: storage, range: tableRange, limitedTo: lineRange)
            } else if let separator = firstAssignmentSeparator(in: source, range: bodyRange) {
                let keyRange = trimmedRange(
                    in: source,
                    range: NSRange(location: bodyRange.location, length: separator - bodyRange.location)
                )
                let valueRange = trimmedRange(
                    in: source,
                    range: NSRange(location: separator + 1, length: NSMaxRange(bodyRange) - separator - 1)
                )
                addColor(palette.property, to: storage, range: keyRange, limitedTo: lineRange)
                let stringTokens = stringTokenRanges(in: source, range: valueRange)
                for stringRange in stringTokens.ranges {
                    addColor(palette.string, to: storage, range: stringRange, limitedTo: lineRange)
                }
                applyUnquoted(numberExpression, color: palette.number, source: source, storage: storage, range: valueRange, excluding: stringTokens.ranges, target: lineRange)
                applyUnquoted(dateExpression, color: palette.number, source: source, storage: storage, range: valueRange, excluding: stringTokens.ranges, target: lineRange)
                applyUnquoted(booleanExpression, color: palette.keyword, source: source, storage: storage, range: valueRange, excluding: stringTokens.ranges, target: lineRange)
                applyInlineProperties(
                    in: valueRange,
                    source: source,
                    storage: storage,
                    palette: palette,
                    excluding: stringTokens.ranges,
                    target: lineRange
                )
                multilineDelimiter = stringTokens.unclosedMultilineDelimiter
            }

            if let commentLocation {
                addColor(
                    palette.comment,
                    to: storage,
                    range: NSRange(location: commentLocation, length: NSMaxRange(contentRange) - commentLocation),
                    limitedTo: lineRange
                )
            }
            cache(multilineDelimiter: multilineDelimiter, after: lineRange, in: storage)
            scannedLineCount += 1
            lineStart = NSMaxRange(lineRange)
            if shouldStop(
                after: lineRange,
                requiredEnd: requiredEnd,
                shouldConverge: shouldConverge,
                cachedExitState: cachedExitState,
                multilineDelimiter: multilineDelimiter
            ) {
                break
            }
        }
        return scannedLineCount
    }

    private static func applyUnquoted(
        _ expression: NSRegularExpression,
        color: NSColor,
        source: NSString,
        storage: NSTextStorage,
        range: NSRange,
        excluding stringRanges: [NSRange],
        target: NSRange
    ) {
        guard range.length > 0 else { return }
        expression.enumerateMatches(in: source as String, range: range) { match, _, _ in
            guard let match, !stringRanges.contains(where: { NSIntersectionRange(match.range, $0).length > 0 }) else {
                return
            }
            addColor(color, to: storage, range: match.range, limitedTo: target)
        }
    }

    private static func applyInlineProperties(
        in range: NSRange,
        source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        excluding stringRanges: [NSRange],
        target: NSRange
    ) {
        guard range.length > 0 else { return }
        inlinePropertyExpression.enumerateMatches(in: source as String, range: range) { match, _, _ in
            guard let match else { return }
            let propertyRange = match.range(at: 1)
            guard !stringRanges.contains(where: {
                NSIntersectionRange(propertyRange, $0).length > 0
            }) else {
                return
            }
            addColor(palette.property, to: storage, range: propertyRange, limitedTo: target)
        }
    }

    private static func updateMultilineState(
        in lineRange: NSRange,
        source: NSString,
        multilineDelimiter: inout String?
    ) {
        let contentRange = lineContentRange(in: source, lineRange: lineRange)
        if let activeMultilineDelimiter = multilineDelimiter {
            if stringClosingRange(
                delimiterCharacter: activeMultilineDelimiter == "\"\"\"" ? 34 : 39,
                isMultiline: true,
                in: source,
                from: contentRange.location,
                limit: NSMaxRange(contentRange)
            ) != nil {
                multilineDelimiter = nil
            }
            return
        }

        let commentLocation = firstCommentLocation(in: source, range: contentRange)
        let bodyRange = NSRange(
            location: contentRange.location,
            length: (commentLocation ?? NSMaxRange(contentRange)) - contentRange.location
        )
        guard let separator = firstAssignmentSeparator(in: source, range: bodyRange) else { return }
        let valueRange = trimmedRange(
            in: source,
            range: NSRange(location: separator + 1, length: NSMaxRange(bodyRange) - separator - 1)
        )
        multilineDelimiter = stringTokenRanges(in: source, range: valueRange).unclosedMultilineDelimiter
    }

    private static func cache(
        multilineDelimiter: String?,
        after lineRange: NSRange,
        in storage: NSTextStorage
    ) {
        guard lineRange.length > 0 else { return }
        storage.addAttribute(
            multilineStateAttribute,
            value: multilineDelimiter ?? "",
            range: NSRange(location: NSMaxRange(lineRange) - 1, length: 1)
        )
    }

    private static func cachedMultilineState(
        at location: Int,
        in storage: NSTextStorage
    ) -> CachedMultilineState? {
        guard location >= 0, location < storage.length,
              let value = storage.attribute(
                  multilineStateAttribute,
                  at: location,
                  effectiveRange: nil
              ) as? String else {
            return nil
        }
        return CachedMultilineState(delimiter: value.isEmpty ? nil : value)
    }

    private static func cachedMultilineState(
        after lineRange: NSRange,
        in storage: NSTextStorage
    ) -> CachedMultilineState? {
        cachedMultilineState(at: NSMaxRange(lineRange) - 1, in: storage)
    }

    private static func cachedMultilineState(
        afterLineEndingAt location: Int,
        in storage: NSTextStorage
    ) -> CachedMultilineState? {
        guard location < storage.length else { return nil }
        let source = storage.string as NSString
        let nextLine = source.lineRange(for: NSRange(location: location, length: 0))
        return cachedMultilineState(after: nextLine, in: storage)
    }

    private static func shouldStop(
        after lineRange: NSRange,
        requiredEnd: Int,
        shouldConverge: Bool,
        cachedExitState: CachedMultilineState?,
        multilineDelimiter: String?
    ) -> Bool {
        let lineEnd = NSMaxRange(lineRange)
        guard lineEnd >= requiredEnd else { return false }
        guard shouldConverge else { return true }
        guard lineRange.location >= requiredEnd else { return false }
        return cachedExitState?.delimiter == multilineDelimiter
    }

    private static func lineRange(containing location: Int, in source: NSString) -> NSRange {
        source.lineRange(
            for: NSRange(location: min(max(0, location), max(0, source.length - 1)), length: 0)
        )
    }

    private static func addColor(
        _ color: NSColor,
        to storage: NSTextStorage,
        range: NSRange,
        limitedTo target: NSRange
    ) {
        let affectedRange = NSIntersectionRange(range, target)
        guard affectedRange.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: affectedRange)
    }

    private static func tableHeaderRange(in source: NSString, range: NSRange) -> NSRange? {
        let trimmed = trimmedRange(in: source, range: range)
        guard trimmed.length >= 3,
              source.character(at: trimmed.location) == 91,
              source.character(at: NSMaxRange(trimmed) - 1) == 93 else {
            return nil
        }
        return trimmed
    }

    private static func firstAssignmentSeparator(in source: NSString, range: NSRange) -> Int? {
        var cursor = range.location
        var inSingleQuote = false
        var inDoubleQuote = false
        while cursor < NSMaxRange(range) {
            let character = source.character(at: cursor)
            if character == 92, inDoubleQuote, cursor + 1 < NSMaxRange(range) {
                cursor += 2
                continue
            }
            if character == 34, !inSingleQuote {
                inDoubleQuote.toggle()
            } else if character == 39, !inDoubleQuote {
                inSingleQuote.toggle()
            } else if character == 61, !inSingleQuote, !inDoubleQuote {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func firstCommentLocation(in source: NSString, range: NSRange) -> Int? {
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let character = source.character(at: cursor)
            guard character == 34 || character == 39 else {
                if character == 35 {
                    return cursor
                }
                cursor += 1
                continue
            }

            let isMultiline = cursor + 2 < NSMaxRange(range)
                && source.character(at: cursor + 1) == character
                && source.character(at: cursor + 2) == character
            guard let closing = stringClosingRange(
                delimiterCharacter: character,
                isMultiline: isMultiline,
                in: source,
                from: cursor + (isMultiline ? 3 : 1),
                limit: NSMaxRange(range)
            ) else {
                return nil
            }
            cursor = NSMaxRange(closing)
        }
        return nil
    }

    private static func stringTokenRanges(in source: NSString, range: NSRange) -> (ranges: [NSRange], unclosedMultilineDelimiter: String?) {
        var ranges: [NSRange] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let character = source.character(at: cursor)
            guard character == 34 || character == 39 else {
                cursor += 1
                continue
            }

            let isMultiline = cursor + 2 < NSMaxRange(range)
                && source.character(at: cursor + 1) == character
                && source.character(at: cursor + 2) == character
            if let closing = stringClosingRange(
                delimiterCharacter: character,
                isMultiline: isMultiline,
                in: source,
                from: cursor + (isMultiline ? 3 : 1),
                limit: NSMaxRange(range)
            ) {
                ranges.append(NSRange(location: cursor, length: NSMaxRange(closing) - cursor))
                cursor = NSMaxRange(closing)
            } else {
                ranges.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
                let multilineDelimiter = character == 34 ? "\"\"\"" : "'''"
                return (ranges, isMultiline ? multilineDelimiter : nil)
            }
        }
        return (ranges, nil)
    }

    private static func stringClosingRange(
        delimiterCharacter: unichar,
        isMultiline: Bool,
        in source: NSString,
        from start: Int,
        limit: Int
    ) -> NSRange? {
        let delimiterLength = isMultiline ? 3 : 1
        var cursor = start
        while cursor + delimiterLength <= limit {
            if delimiterCharacter == 34,
               source.character(at: cursor) == 92,
               cursor + 1 < limit {
                cursor += 2
                continue
            }
            guard source.character(at: cursor) == delimiterCharacter else {
                cursor += 1
                continue
            }
            if !isMultiline {
                return NSRange(location: cursor, length: 1)
            }
            if source.character(at: cursor + 1) == delimiterCharacter,
               source.character(at: cursor + 2) == delimiterCharacter {
                return NSRange(location: cursor, length: 3)
            }
            cursor += 1
        }
        return nil
    }

    private static func lineContentRange(in source: NSString, lineRange: NSRange) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = source.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private static func trimmedRange(in source: NSString, range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(source.character(at: start)) {
            start += 1
        }
        while end > start, isWhitespace(source.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    private static func expression(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
