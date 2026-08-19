import AppKit

/// Retains the editor's existing generic token treatment for unmapped formats.
enum GenericSyntaxHighlightingAdapter {
    private static let keywordExpression = expression(
        #"\b(class|struct|enum|protocol|extension|func|let|var|if|else|guard|switch|case|for|while|return|throw|throws|try|catch|async|await|public|private|internal|protected|static|final|new|import|package|interface|implements|extends|void|boolean|int|long|const|function|def|in|from|as|true|false|null|nil|self|this)\b"#
    )
    private static let annotationExpression = expression(#"@[A-Za-z_][A-Za-z0-9_]*"#)
    private static let typeExpression = expression(#"\b[A-Z][A-Za-z0-9_]*\b"#)
    private static let numberExpression = expression(#"\b\d+(?:\.\d+)?\b"#)
    private static let stringExpression = expression(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#)
    private static let commentExpression = expression(
        #"//.*$|#.*$|/\*[\s\S]*?\*/"#,
        options: [.anchorsMatchLines]
    )

    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range: NSRange) {
        apply(keywordExpression, color: palette.keyword, storage: storage, range: range)
        apply(annotationExpression, color: palette.annotation, storage: storage, range: range)
        apply(typeExpression, color: palette.type, storage: storage, range: range)
        apply(numberExpression, color: palette.number, storage: storage, range: range)
        apply(stringExpression, color: palette.string, storage: storage, range: range)
        apply(commentExpression, color: palette.comment, storage: storage, range: range)
    }

    static func apply(
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

    private static func expression(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
