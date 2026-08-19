import AppKit

/// Performs lightweight XML tag, attribute, value, declaration, and comment highlighting.
enum XMLSyntaxHighlightingAdapter {
    private static let declarationExpression = expression(
        #"<\?(?:[A-Za-z_][A-Za-z0-9_.:-]*)|<!DOCTYPE\b"#,
        options: [.caseInsensitive]
    )
    private static let tagNameExpression = expression(
        #"</?\s*([A-Za-z_][A-Za-z0-9_.:-]*)"#
    )
    private static let attributeNameExpression = expression(
        #"\s+([A-Za-z_:][A-Za-z0-9_.:-]*)(?=\s*=)"#
    )
    private static let stringExpression = expression(#"\"[^\"]*\"|'[^']*'"#)
    private static let cdataExpression = expression(#"<!\[CDATA\[[\s\S]*?\]\]>"#)
    private static let commentExpression = expression(#"<!--[\s\S]*?-->"#)

    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range target: NSRange) {
        apply(declarationExpression, color: palette.annotation, storage: storage, range: target)
        apply(tagNameExpression, captureGroup: 1, color: palette.type, storage: storage, range: target)
        apply(attributeNameExpression, captureGroup: 1, color: palette.property, storage: storage, range: target)
        apply(stringExpression, color: palette.string, storage: storage, range: target)
        apply(cdataExpression, color: palette.string, storage: storage, range: target)
        apply(commentExpression, color: palette.comment, storage: storage, range: target)
    }

    private static func apply(
        _ expression: NSRegularExpression,
        captureGroup: Int = 0,
        color: NSColor,
        storage: NSTextStorage,
        range: NSRange
    ) {
        expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range(at: captureGroup))
        }
    }

    private static func expression(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
