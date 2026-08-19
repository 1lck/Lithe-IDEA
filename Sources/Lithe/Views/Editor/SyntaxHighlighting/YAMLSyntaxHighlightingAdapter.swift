import AppKit

/// Applies a line-oriented YAML token pass without requiring a full YAML parser.
/// YAML comments and mapping separators are context-sensitive, so this adapter scans
/// each affected line before using regular expressions for individual token kinds.
enum YAMLSyntaxHighlightingAdapter {
    private static let documentMarkerExpression = try! NSRegularExpression(
        pattern: #"^\s*(?:---|\.\.\.)(?=\s|$)"#
    )
    private static let keyExpression = try! NSRegularExpression(
        pattern: #"^\s*(?:-\s+)?((?:\"(?:\\.|[^\"\\])*\"|'(?:''|[^'])*')|(?:[^\s#][^:#]*?))\s*:(?=\s|$)"#
    )
    private static let stringExpression = try! NSRegularExpression(
        pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:''|[^'])*'"#
    )
    private static let numberExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.-])[-+]?(?:0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|(?:\d[\d_]*)(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?)\b"#
    )
    private static let literalExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.-])(?:true|false|null|~)(?![A-Za-z0-9_.-])"#,
        options: [.caseInsensitive]
    )
    private static let referenceExpression = try! NSRegularExpression(
        pattern: #"(?<!\S)[&*!][A-Za-z0-9_-]+"#
    )

    static func apply(to storage: NSTextStorage, palette: CodeEditorPalette, range: NSRange) {
        let source = storage.string as NSString
        let upperBound = NSMaxRange(range)
        var location = range.location

        while location < upperBound {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let activeRange = NSIntersectionRange(lineRange, range)
            guard activeRange.length > 0 else {
                location = max(NSMaxRange(lineRange), location + 1)
                continue
            }

            let contentRange = rangeBeforeComment(in: source, lineRange: lineRange)
            let highlightedContentRange = NSIntersectionRange(contentRange, range)
            if highlightedContentRange.length > 0 {
                applyTokens(to: storage, palette: palette, range: highlightedContentRange)
            }
            if NSMaxRange(contentRange) < NSMaxRange(lineRange) {
                let commentRange = NSIntersectionRange(
                    NSRange(location: NSMaxRange(contentRange), length: NSMaxRange(lineRange) - NSMaxRange(contentRange)),
                    range
                )
                if commentRange.length > 0 {
                    storage.addAttribute(.foregroundColor, value: palette.comment, range: commentRange)
                }
            }
            location = NSMaxRange(lineRange)
        }
    }

    private static func applyTokens(to storage: NSTextStorage, palette: CodeEditorPalette, range: NSRange) {
        SyntaxHighlightingAdapterSupport.apply(documentMarkerExpression, color: palette.keyword, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(stringExpression, color: palette.string, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(numberExpression, color: palette.number, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(literalExpression, color: palette.keyword, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(referenceExpression, color: palette.annotation, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(keyExpression, color: palette.property, storage: storage, range: range, captureGroup: 1)
    }

    private static func rangeBeforeComment(in source: NSString, lineRange: NSRange) -> NSRange {
        var quote: unichar?
        var isEscaped = false
        let lineEnd = NSMaxRange(lineRange)
        var location = lineRange.location

        while location < lineEnd {
            let character = source.character(at: location)
            if let activeQuote = quote {
                if activeQuote == 34, character == 92, !isEscaped {
                    isEscaped = true
                    location += 1
                    continue
                }
                if character == activeQuote, !isEscaped {
                    if activeQuote == 39,
                       location + 1 < lineEnd,
                       source.character(at: location + 1) == 39 {
                        location += 2
                        continue
                    }
                    quote = nil
                } else {
                    isEscaped = false
                }
                location += 1
                continue
            }

            if character == 34 || character == 39 {
                quote = character
                location += 1
                continue
            }
            if character == 35,
               (location == lineRange.location || isSeparationWhitespace(source.character(at: location - 1))) {
                return NSRange(location: lineRange.location, length: location - lineRange.location)
            }
            location += 1
        }
        return lineRange
    }

    private static func isSeparationWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }
}
