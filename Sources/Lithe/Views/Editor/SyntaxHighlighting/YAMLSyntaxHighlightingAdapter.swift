import AppKit

/// Performs lightweight, line-oriented YAML tokenization without a parser dependency.
enum YAMLSyntaxHighlightingAdapter {
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

    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range target: NSRange) {
        let source = storage.string as NSString
        var lineStart = 0
        var blockScalarIndent: Int?
        let scanLimit = min(NSMaxRange(target), source.length)

        // Block scalar state can begin before the dirty range, so scan from the
        // document start and only mutate attributes intersecting the target.
        while lineStart < scanLimit {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentRange = lineContentRange(in: source, lineRange: lineRange)
            let indentation = indentationLength(in: source, range: contentRange)

            if let scalarIndent = blockScalarIndent {
                if isBlank(in: source, range: contentRange) || indentation > scalarIndent {
                    addColor(palette.string, to: storage, range: contentRange, limitedTo: target)
                    lineStart = NSMaxRange(lineRange)
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
                target: target
            )
            if let commentLocation {
                addColor(
                    palette.comment,
                    to: storage,
                    range: NSRange(location: commentLocation, length: NSMaxRange(contentRange) - commentLocation),
                    limitedTo: target
                )
            }
            if isBlockScalarHeader(in: source, range: bodyRange) {
                blockScalarIndent = indentation
            }
            lineStart = NSMaxRange(lineRange)
        }
    }

    private static func applyLineTokens(
        in range: NSRange,
        source: NSString,
        storage: NSTextStorage,
        palette: SyntaxHighlightingPalette,
        target: NSRange
    ) {
        apply(stringExpression, color: palette.string, source: source, storage: storage, range: range, target: target)
        apply(numberExpression, color: palette.number, source: source, storage: storage, range: range, target: target)
        apply(keywordExpression, color: palette.keyword, source: source, storage: storage, range: range, target: target)
        apply(anchorOrAliasExpression, color: palette.annotation, source: source, storage: storage, range: range, target: target)
        apply(tagExpression, color: palette.annotation, source: source, storage: storage, range: range, target: target)
        apply(
            mappingKeyExpression,
            captureGroup: 1,
            color: palette.property,
            source: source,
            storage: storage,
            range: range,
            target: target
        )
        apply(
            explicitKeyExpression,
            captureGroup: 1,
            color: palette.property,
            source: source,
            storage: storage,
            range: range,
            target: target
        )
    }

    private static func apply(
        _ expression: NSRegularExpression,
        captureGroup: Int = 0,
        color: NSColor,
        source: NSString,
        storage: NSTextStorage,
        range: NSRange,
        target: NSRange
    ) {
        guard range.length > 0 else { return }
        expression.enumerateMatches(in: source as String, range: range) { match, _, _ in
            guard let match else { return }
            addColor(color, to: storage, range: match.range(at: captureGroup), limitedTo: target)
        }
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
