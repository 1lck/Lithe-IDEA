import AppKit

/// Adds JSON object-property treatment after generic string tokenization.
enum JSONSyntaxHighlightingAdapter {
    private static let propertyExpression = try! NSRegularExpression(
        pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#
    )

    static func apply(to storage: NSTextStorage, palette: SyntaxHighlightingPalette, range: NSRange) {
        GenericSyntaxHighlightingAdapter.apply(
            propertyExpression,
            color: palette.property,
            storage: storage,
            range: range
        )
    }
}
