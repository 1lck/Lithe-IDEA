import AppKit

/// Keeps lexical and Java semantic colors in the same viewport cache so a
/// lexical refresh cannot overwrite semantic colors without reapplying them.
struct EditorSyntaxHighlightState {
    private var paintedRanges = HighlightedRangeCache()
    private var javaHighlights = JavaSemanticHighlightIndex([], documentLength: 0)

    mutating func replaceJavaHighlights(_ highlights: [JavaSyntaxHighlight], documentLength: Int) {
        javaHighlights = JavaSemanticHighlightIndex(highlights, documentLength: documentLength)
        invalidateAppearance()
    }

    mutating func invalidateText() {
        javaHighlights = JavaSemanticHighlightIndex([], documentLength: 0)
        invalidateAppearance()
    }

    mutating func invalidateAppearance() {
        paintedRanges.removeAll()
    }

    mutating func applyEdit(replacedRange: NSRange, replacementLength: Int, isJava: Bool) {
        if isJava {
            // Even a same-length edit can change names and multiline lexical
            // state outside the edited line. Never reuse tokens from that text.
            invalidateText()
        } else {
            paintedRanges.applyEdit(replacedRange: replacedRange, replacementLength: replacementLength)
        }
    }

    mutating func apply(
        to storage: NSTextStorage,
        font: NSFont,
        fileName: String? = nil,
        fileExtension: String,
        isDark: Bool,
        range: NSRange,
        force: Bool = false
    ) {
        let target = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        for uncovered in force ? [target] : paintedRanges.uncoveredRanges(in: target) {
            SyntaxHighlighter.applyExact(
                to: storage, font: font, fileName: fileName,
                fileExtension: fileExtension, isDark: isDark, range: uncovered
            )
            SyntaxHighlighter.applyJavaSemanticHighlights(
                javaHighlights.intersecting(uncovered),
                to: storage, isDark: isDark, range: uncovered
            )
            paintedRanges.insert(uncovered)
        }
    }
}

/// A balanced interval index includes tokens starting before the viewport
/// (for example text blocks) without scanning every earlier token on scroll.
struct JavaSemanticHighlightIndex {
    private struct Entry {
        let highlight: JavaSyntaxHighlight
        let ordinal: Int
        var subtreeEnd: Int
    }

    private var entries: [Entry]

    init(_ highlights: [JavaSyntaxHighlight], documentLength: Int) {
        entries = highlights.enumerated().compactMap { ordinal, highlight in
            let range = highlight.range
            guard range.location >= 0, range.location <= documentLength,
                  range.length > 0, range.length <= documentLength - range.location else { return nil }
            return Entry(highlight: highlight, ordinal: ordinal, subtreeEnd: NSMaxRange(range))
        }.sorted {
            if $0.highlight.range.location != $1.highlight.range.location {
                return $0.highlight.range.location < $1.highlight.range.location
            }
            return $0.ordinal < $1.ordinal
        }
        _ = buildSubtree(in: entries.indices)
    }

    private mutating func buildSubtree(in bounds: Range<Int>) -> Int {
        guard !bounds.isEmpty else { return 0 }
        let middle = bounds.lowerBound + bounds.count / 2
        let leftEnd = buildSubtree(in: bounds.lowerBound..<middle)
        let rightEnd = buildSubtree(in: (middle + 1)..<bounds.upperBound)
        let end = max(NSMaxRange(entries[middle].highlight.range), max(leftEnd, rightEnd))
        entries[middle].subtreeEnd = end
        return end
    }

    func intersecting(_ range: NSRange) -> [JavaSyntaxHighlight] {
        guard range.length > 0 else { return [] }
        var matches: [Entry] = []
        collect(in: entries.indices, intersecting: range, into: &matches)
        // Preserve the producer's precedence when semantic spans overlap.
        return matches.sorted { $0.ordinal < $1.ordinal }.map(\.highlight)
    }

    private func collect(in bounds: Range<Int>, intersecting range: NSRange, into matches: inout [Entry]) {
        guard !bounds.isEmpty else { return }
        let middle = bounds.lowerBound + bounds.count / 2
        guard entries[middle].subtreeEnd > range.location,
              entries[bounds.lowerBound].highlight.range.location < NSMaxRange(range) else { return }
        collect(in: bounds.lowerBound..<middle, intersecting: range, into: &matches)
        if NSIntersectionRange(entries[middle].highlight.range, range).length > 0 {
            matches.append(entries[middle])
        }
        collect(in: (middle + 1)..<bounds.upperBound, intersecting: range, into: &matches)
    }
}
