import Foundation

enum MarkdownImageInsertion {
    static func blockText(
        reference: String,
        in source: String,
        replacing range: NSRange
    ) -> String {
        let source = source as NSString
        guard range.location != NSNotFound,
              range.location <= source.length,
              range.length <= source.length - range.location else {
            return reference
        }

        let prefix = source.substring(to: range.location)
        let suffix = source.substring(from: NSMaxRange(range))
        return separatorAfter(prefix) + reference + separatorBefore(suffix)
    }

    private static func separatorAfter(_ prefix: String) -> String {
        guard !prefix.isEmpty else { return "" }
        if hasTwoTrailingLineBreaks(prefix) { return "" }
        if hasTrailingLineBreak(prefix) { return "\n" }
        return "\n\n"
    }

    private static func separatorBefore(_ suffix: String) -> String {
        guard !suffix.isEmpty else { return "" }
        if hasTwoLeadingLineBreaks(suffix) { return "" }
        if hasLeadingLineBreak(suffix) { return "\n" }
        return "\n\n"
    }

    private static func hasTrailingLineBreak(_ value: String) -> Bool {
        value.hasSuffix("\n") || value.hasSuffix("\r")
    }

    private static func hasTwoTrailingLineBreaks(_ value: String) -> Bool {
        value.hasSuffix("\n\n")
            || value.hasSuffix("\r\r")
            || value.hasSuffix("\r\n\r\n")
    }

    private static func hasLeadingLineBreak(_ value: String) -> Bool {
        value.hasPrefix("\n") || value.hasPrefix("\r")
    }

    private static func hasTwoLeadingLineBreaks(_ value: String) -> Bool {
        value.hasPrefix("\n\n")
            || value.hasPrefix("\r\r")
            || value.hasPrefix("\r\n\r\n")
    }
}
