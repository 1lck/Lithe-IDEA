import AppKit

enum JSONSyntaxHighlightingAdapter {
    private static let propertyExpression = try! NSRegularExpression(
        pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#
    )

    static func apply(to storage: NSTextStorage, palette: CodeEditorPalette, range: NSRange) {
        SyntaxHighlightingAdapterSupport.apply(propertyExpression, color: palette.property, storage: storage, range: range)
    }
}
