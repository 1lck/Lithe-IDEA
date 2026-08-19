import AppKit

enum GenericSyntaxHighlightingAdapter {
    private static let keywordExpression = try! NSRegularExpression(
        pattern: #"\b(class|struct|enum|protocol|extension|func|let|var|if|else|guard|switch|case|for|while|return|throw|throws|try|catch|async|await|public|private|internal|protected|static|final|new|import|package|interface|implements|extends|void|boolean|int|long|const|function|def|in|from|as|true|false|null|nil|self|this)\b"#
    )
    private static let annotationExpression = try! NSRegularExpression(
        pattern: #"@[A-Za-z_][A-Za-z0-9_]*"#
    )
    private static let typeExpression = try! NSRegularExpression(
        pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#
    )
    private static let numberExpression = try! NSRegularExpression(
        pattern: #"\b\d+(?:\.\d+)?\b"#
    )
    private static let stringExpression = try! NSRegularExpression(
        pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
    )
    private static let commentExpression = try! NSRegularExpression(
        pattern: #"//.*$|#.*$|/\*[\s\S]*?\*/"#,
        options: [.anchorsMatchLines]
    )

    static func apply(to storage: NSTextStorage, palette: CodeEditorPalette, range: NSRange) {
        SyntaxHighlightingAdapterSupport.apply(keywordExpression, color: palette.keyword, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(annotationExpression, color: palette.annotation, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(typeExpression, color: palette.type, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(numberExpression, color: palette.number, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(stringExpression, color: palette.string, storage: storage, range: range)
        SyntaxHighlightingAdapterSupport.apply(commentExpression, color: palette.comment, storage: storage, range: range)
    }
}
