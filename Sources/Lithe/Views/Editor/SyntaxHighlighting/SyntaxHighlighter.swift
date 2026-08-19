import AppKit

/// Applies the adapter selected by the bundled file-format mapping.
enum SyntaxHighlighter {
    static func apply(
        to storage: NSTextStorage,
        font: NSFont,
        fileName: String? = nil,
        fileExtension: String,
        isDark: Bool,
        range: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }
        let target = targetRange(for: range, in: storage.string as NSString, limit: fullRange)
        applyExact(
            to: storage,
            font: font,
            fileName: fileName,
            fileExtension: fileExtension,
            isDark: isDark,
            range: target
        )
    }

    static func applyExact(
        to storage: NSTextStorage,
        font: NSFont,
        fileName: String? = nil,
        fileExtension: String,
        isDark: Bool,
        range target: NSRange
    ) {
        guard target.length > 0 else { return }
        let palette = CodeEditorPalette(isDark: isDark, theme: LitheTheme.activeTheme)
        let adapter = SyntaxHighlightingRegistry.bundled.adapter(
            fileName: fileName,
            fileExtension: fileExtension
        )

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .paragraphStyle: LitheTheme.editorParagraphStyle,
            .ligature: 0,
            .foregroundColor: palette.text
        ], range: target)

        switch adapter {
        case .generic:
            GenericSyntaxHighlightingAdapter.apply(to: storage, palette: palette, range: target)
        case .json:
            GenericSyntaxHighlightingAdapter.apply(to: storage, palette: palette, range: target)
            JSONSyntaxHighlightingAdapter.apply(to: storage, palette: palette, range: target)
        case .yaml:
            YAMLSyntaxHighlightingAdapter.apply(to: storage, palette: palette, range: target)
        }
        storage.endEditing()
    }

    /// Re-color the edited lines plus a small pad so a token that crosses the
    /// caret, or a nearby block comment, is not left half-styled.
    static func targetRange(for range: NSRange?, in source: NSString, limit: NSRange) -> NSRange {
        guard let range else { return limit }
        let safe = NSIntersectionRange(range, limit)
        guard source.length > 0 else { return safe }
        let startLine = source.lineRange(for: NSRange(location: safe.location, length: 0))
        let endIndex = max(safe.location, NSMaxRange(safe) > 0 ? NSMaxRange(safe) - 1 : 0)
        let endLine = source.lineRange(for: NSRange(location: min(endIndex, source.length - 1), length: 0))
        var combined = NSUnionRange(startLine, endLine)
        if combined.location > 0 {
            combined = NSUnionRange(
                source.lineRange(for: NSRange(location: combined.location - 1, length: 0)),
                combined
            )
        }
        if NSMaxRange(combined) < source.length {
            combined = NSUnionRange(
                combined,
                source.lineRange(for: NSRange(location: NSMaxRange(combined), length: 0))
            )
        }
        return NSIntersectionRange(combined, limit)
    }
}
