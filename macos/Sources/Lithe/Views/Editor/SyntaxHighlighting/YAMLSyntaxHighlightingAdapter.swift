import AppKit

/// Performs lightweight, line-oriented YAML tokenization without a parser dependency.
enum YAMLSyntaxHighlightingAdapter {
    /// Lexer state cached after a physical line; `nil` means normal YAML content.
    private struct CachedBlockScalarState {
        let indent: Int?
    }

    private static let blockScalarStateAttribute = NSAttributedString.Key("lithe.yaml.block-scalar-state")
    private static let stringExpression = expression(#"\"(?:\\.|[^\"\\])*\"|'(?:''|[^'])*'"#)
    private static let numberExpression = expression(
        #"(?<![A-Za-z0-9_.-])[-+]?(?:0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?)(?![A-Za-z0-9_.-])"#
    )
    private static let keywordExpression = expression(
        #"(?<![A-Za-z0-9_.-])(?:true|false|null|~|---|\.\.\.|%YAML|%TAG)(?![A-Za-z0-9_.-])"#,
        options: [.caseInsensitive]
    )
    private static let anchorOrAliasExpression = expression(#"(?:&|\*)[A-Za-z0-9_-]+"#)
    private static let tagExpression = expression(#"![A-Za-z][A-Za-z0-9!:_-]*"#)
    private static let mappingKeyExpression = expression(
        #"(?:^|[,{])[ \t]*(?:-[ \t]+)?([A-Za-z_][A-Za-z0-9_.-]*|\"(?:\\.|[^\"\\])*\"|'(?:''|[^'])*')(?=[ \t]*:)"#,
        options: [.anchorsMatchLines]
    )
    private static let explicitKeyExpression = expression(
        #"^[ \t]*\?[ \t]+(.+?)[ \t]*$"#,
        options: [.anchorsMatchLines]
    )

    @discardableResult
    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range target: NSRange) -> Int {
        let source = storage.string as NSString
        guard source.length > 0 else { return 0 }
        let scanStart = lineRange(containing: target.location, in: source).location
        let requiredEnd = NSMaxRange(lineRange(containing: max(target.location, NSMaxRange(target) - 1), in: source))
        let cachedStateBeforeTarget = cachedBlockScalarIndent(at: scanStart - 1, in: storage)
        let shouldConverge = cachedStateBeforeTarget != nil
            || cachedBlockScalarIndent(afterLineEndingAt: requiredEnd, in: storage) != nil
        var blockScalarIndent = cachedStateBeforeTarget?.indent
        var scannedLineCount = 0

        // Line-ending attributes move with NSTextStorage edits, so an unchanged
        // predecessor restores state in O(1) and rescanning stops after convergence.
        if cachedStateBeforeTarget == nil, scanStart > 0 {
            var prefixLineStart = 0
            while prefixLineStart < scanStart {
                let lineRange = source.lineRange(for: NSRange(location: prefixLineStart, length: 0))
                updateBlockScalarState(
                    in: lineRange,
                    source: source,
                    blockScalarIndent: &blockScalarIndent
                )
                cache(blockScalarIndent: blockScalarIndent, after: lineRange, in: storage)
                prefixLineStart = NSMaxRange(lineRange)
                scannedLineCount += 1
            }
        }

        storage.removeAttribute(
            blockScalarStateAttribute,
            range: NSRange(location: scanStart, length: max(0, requiredEnd - scanStart))
        )

        var lineStart = scanStart
        while lineStart < source.length {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let cachedExitState = cachedBlockScalarIndent(after: lineRange, in: storage)
            let contentRange = lineContentRange(in: source, lineRange: lineRange)
            let indentation = indentationLength(in: source, range: contentRange)
            storage.addAttribute(.foregroundColor, value: palette.text, range: lineRange)

            if let scalarIndent = blockScalarIndent {
                if isBlank(in: source, range: contentRange) || indentation > scalarIndent {
                    addColor(palette.string, to: storage, range: contentRange, limitedTo: lineRange)
                    cache(blockScalarIndent: blockScalarIndent, after: lineRange, in: storage)
                    scannedLineCount += 1
                    lineStart = NSMaxRange(lineRange)
                    if shouldStop(
                        after: lineRange,
                        requiredEnd: requiredEnd,
                        shouldConverge: shouldConverge,
                        cachedExitState: cachedExitState,
                        blockScalarIndent: blockScalarIndent
                    ) {
                        break
                    }
                    continue
                }
                blockScalarIndent = nil
            }

            let commentLocation = firstCommentLocation(in: source, range: contentRange)
            let bodyRange = NSRange(
                location: contentRange.location,
                length: (commentLocation ?? NSMaxRange(contentRange)) - contentRange.location
            )
            applyLineTokens(
                in: bodyRange,
                source: source,
                storage: storage,
                palette: palette,
                target: lineRange
            )
            if let commentLocation {
                addColor(
                    palette.comment,
                    to: storage,
                    range: NSRange(location: commentLocation, length: NSMaxRange(contentRange) - commentLocation),
                    limitedTo: lineRange
                )
            }
            if isBlockScalarHeader(in: source, range: bodyRange) {
                blockScalarIndent = indentation
            }
            cache(blockScalarIndent: blockScalarIndent, after: lineRange, in: storage)
            scannedLineCount += 1
            lineStart = NSMaxRange(lineRange)
            if shouldStop(
                after: lineRange,
                requiredEnd: requiredEnd,
                shouldConverge: shouldConverge,
                cachedExitState: cachedExitState,
                blockScalarIndent: blockScalarIndent
            ) {
                break
            }
        }
        return scannedLineCount
    }

    private static func applyLineTokens(
        in range: NSRange,
        source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        target: NSRange
    ) {
        let stringRanges = matches(of: stringExpression, in: source, range: range)
        apply(numberExpression, color: palette.number, source: source, storage: storage, range: range, target: target)
        apply(keywordExpression, color: palette.keyword, source: source, storage: storage, range: range, target: target)
        apply(anchorOrAliasExpression, color: palette.annotation, source: source, storage: storage, range: range, target: target)
        apply(tagExpression, color: palette.annotation, source: source, storage: storage, range: range, target: target)
        apply(stringExpression, color: palette.string, source: source, storage: storage, range: range, target: target)
        apply(
            mappingKeyExpression,
            captureGroup: 1,
            color: palette.property,
            source: source,
            storage: storage,
            range: range,
            target: target,
            excluding: stringRanges,
            allowingExactProtectedRange: true
        )
        apply(
            explicitKeyExpression,
            captureGroup: 1,
            color: palette.property,
            source: source,
            storage: storage,
            range: range,
            target: target,
            excluding: stringRanges,
            allowingExactProtectedRange: true
        )
    }

    private static func apply(
        _ expression: NSRegularExpression,
        captureGroup: Int = 0,
        color: NSColor,
        source: NSString,
        storage: NSTextStorage,
        range: NSRange,
        target: NSRange,
        excluding protectedRanges: [NSRange] = [],
        allowingExactProtectedRange: Bool = false
    ) {
        guard range.length > 0 else { return }
        expression.enumerateMatches(in: source as String, range: range) { match, _, _ in
            guard let match else { return }
            let capturedRange = match.range(at: captureGroup)
            let overlapsProtectedRange = protectedRanges.contains { protectedRange in
                NSIntersectionRange(capturedRange, protectedRange).length > 0
                    && !(allowingExactProtectedRange && NSEqualRanges(capturedRange, protectedRange))
            }
            guard !overlapsProtectedRange else { return }
            addColor(color, to: storage, range: capturedRange, limitedTo: target)
        }
    }

    private static func matches(
        of expression: NSRegularExpression,
        in source: NSString,
        range: NSRange
    ) -> [NSRange] {
        expression.matches(in: source as String, range: range).map(\.range)
    }

    private static func updateBlockScalarState(
        in lineRange: NSRange,
        source: NSString,
        blockScalarIndent: inout Int?
    ) {
        let contentRange = lineContentRange(in: source, lineRange: lineRange)
        let indentation = indentationLength(in: source, range: contentRange)
        if let scalarIndent = blockScalarIndent {
            if isBlank(in: source, range: contentRange) || indentation > scalarIndent {
                return
            }
            blockScalarIndent = nil
        }
        let commentLocation = firstCommentLocation(in: source, range: contentRange)
        let bodyRange = NSRange(
            location: contentRange.location,
            length: (commentLocation ?? NSMaxRange(contentRange)) - contentRange.location
        )
        if isBlockScalarHeader(in: source, range: bodyRange) {
            blockScalarIndent = indentation
        }
    }

    private static func cache(
        blockScalarIndent: Int?,
        after lineRange: NSRange,
        in storage: NSTextStorage
    ) {
        guard lineRange.length > 0 else { return }
        storage.addAttribute(
            blockScalarStateAttribute,
            value: NSNumber(value: blockScalarIndent ?? -1),
            range: NSRange(location: NSMaxRange(lineRange) - 1, length: 1)
        )
    }

    private static func cachedBlockScalarIndent(
        at location: Int,
        in storage: NSTextStorage
    ) -> CachedBlockScalarState? {
        guard location >= 0, location < storage.length,
              let value = storage.attribute(
                  blockScalarStateAttribute,
                  at: location,
                  effectiveRange: nil
              ) as? NSNumber else {
            return nil
        }
        return CachedBlockScalarState(indent: value.intValue >= 0 ? value.intValue : nil)
    }

    private static func cachedBlockScalarIndent(
        after lineRange: NSRange,
        in storage: NSTextStorage
    ) -> CachedBlockScalarState? {
        cachedBlockScalarIndent(at: NSMaxRange(lineRange) - 1, in: storage)
    }

    private static func cachedBlockScalarIndent(
        afterLineEndingAt location: Int,
        in storage: NSTextStorage
    ) -> CachedBlockScalarState? {
        guard location < storage.length else { return nil }
        let source = storage.string as NSString
        let nextLine = source.lineRange(for: NSRange(location: location, length: 0))
        return cachedBlockScalarIndent(after: nextLine, in: storage)
    }

    private static func shouldStop(
        after lineRange: NSRange,
        requiredEnd: Int,
        shouldConverge: Bool,
        cachedExitState: CachedBlockScalarState?,
        blockScalarIndent: Int?
    ) -> Bool {
        let lineEnd = NSMaxRange(lineRange)
        guard lineEnd >= requiredEnd else { return false }
        guard shouldConverge else { return true }
        guard lineRange.location >= requiredEnd else { return false }
        return cachedExitState?.indent == blockScalarIndent
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

    private static func firstCommentLocation(in source: NSString, range: NSRange) -> Int? {
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
            } else if character == 35,
                      !inSingleQuote,
                      !inDoubleQuote,
                      (cursor == range.location || isWhitespace(source.character(at: cursor - 1))) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func isBlockScalarHeader(in source: NSString, range: NSRange) -> Bool {
        guard let separator = firstUnquotedColon(in: source, range: range) else { return false }
        var cursor = separator + 1
        while cursor < NSMaxRange(range), isWhitespace(source.character(at: cursor)) {
            cursor += 1
        }
        guard cursor < NSMaxRange(range) else { return false }
        let marker = source.character(at: cursor)
        return marker == 124 || marker == 62
    }

    private static func firstUnquotedColon(in source: NSString, range: NSRange) -> Int? {
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
            } else if character == 58, !inSingleQuote, !inDoubleQuote {
                return cursor
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

    private static func indentationLength(in source: NSString, range: NSRange) -> Int {
        var cursor = range.location
        while cursor < NSMaxRange(range), isWhitespace(source.character(at: cursor)) {
            cursor += 1
        }
        return cursor - range.location
    }

    private static func isBlank(in source: NSString, range: NSRange) -> Bool {
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            guard isWhitespace(source.character(at: cursor)) else { return false }
            cursor += 1
        }
        return true
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
