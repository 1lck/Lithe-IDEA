import AppKit

/// Highlights JSON tokens without applying comment rules from the generic code adapter.
enum JSONSyntaxHighlightingAdapter {
    private static let numberExpression = expression(
        #"(?<![A-Za-z0-9_.-])-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?(?![A-Za-z0-9_.-])"#
    )
    private static let keywordExpression = expression(#"\b(?:true|false|null)\b"#)
    private static let stringExpression = expression(#"\"(?:\\.|[^\"\\])*\""#)
    private static let propertyExpression = try! NSRegularExpression(
        pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#
    )

    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range: NSRange) {
        apply(numberExpression, color: palette.number, storage: storage, range: range)
        apply(keywordExpression, color: palette.keyword, storage: storage, range: range)
        apply(stringExpression, color: palette.string, storage: storage, range: range)
        apply(propertyExpression, color: palette.property, storage: storage, range: range)
    }

    private static func apply(
        _ expression: NSRegularExpression,
        color: NSColor,
        storage: NSTextStorage,
        range: NSRange
    ) {
        expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
