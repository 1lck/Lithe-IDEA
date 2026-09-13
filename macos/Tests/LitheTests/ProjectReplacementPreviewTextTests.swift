import AppKit
import SwiftUI
import Testing
import LitheSearchModule
@testable import Lithe

@Suite("Replacement source preview")
@MainActor
struct ProjectReplacementPreviewTextTests {
    @Test
    func previewGutterUsesEqualInsetsAndDividerSpacingForAllDigitCounts() {
        for textWidth in [14.0, 28.0, 42.0] {
            let layout = EditorGutterLayout(lineNumberTextWidth: textWidth, isSearchPreview: true)
            #expect(layout.lineNumberRange.lowerBound == EditorGutterLayout.previewSpacing)
            #expect(layout.numberTrailingPadding == EditorGutterLayout.previewSpacing)
            #expect(layout.width - layout.lineNumberRange.upperBound == EditorGutterLayout.previewSpacing)
            #expect(layout.lineNumberRange.upperBound - layout.lineNumberRange.lowerBound >= textWidth + layout.numberTrailingPadding)
            #expect(layout.breakpointInteractionRange.isEmpty)
        }
    }

    @Test
    func sourceSnippetsExposeSyntaxColorsToSwiftUI() {
        let value = ProjectReplacementPreviewText.highlighted(
            "<root value=\"22\">text</root>", query: "22", options: .default,
            fileName: "pom.xml", isDark: true
        )
        #expect(value.runs.contains { $0.foregroundColor != nil })
        #expect(value.runs.contains { $0.backgroundColor != nil })
        #expect(Set(value.runs.compactMap { $0.foregroundColor }).count > 1)
    }

    @Test
    func preservesSourceLineNumbersAcrossLineEndings() {
        #expect(ProjectReplacementPreviewText.lines("first\r\n\r\nthird\n") == ["first", "", "third", ""])
        // Search results count LF separators, including in mixed-line-ending files.
        #expect(ProjectReplacementPreviewText.lines("first\rsecond\nthird") == ["first\rsecond", "third"])
    }

    @Test
    func highlightsRepeatedUnicodeMatchesAndHonorsOptions() {
        func highlightedRanges(_ text: String, query: String, options: ProjectSearchOptions = .default) -> [NSRange] {
            let value = ProjectReplacementPreviewText.highlighted(text, query: query, options: options)
            // Assert the attributes rendered by SwiftUI; an AppKit round-trip drops these colors.
            return value.runs.compactMap { run in
                guard run.backgroundColor != nil else { return nil }
                let location = String(value.characters[..<run.range.lowerBound]).utf16.count
                let length = String(value[run.range].characters).utf16.count
                return NSRange(location: location, length: length)
            }
        }
        #expect(highlightedRanges("😀22 / 22", query: "22") == [NSRange(location: 2, length: 2), NSRange(location: 7, length: 2)])
        #expect(highlightedRanges("Foo foo food", query: "foo", options: .init(caseSensitive: true, wholeWords: true)) == [NSRange(location: 4, length: 3)])
        #expect(highlightedRanges("a22 b333", query: "[0-9]+", options: .init(regularExpression: true)) == [NSRange(location: 1, length: 2), NSRange(location: 5, length: 3)])
        #expect(highlightedRanges("abc", query: "[", options: .init(regularExpression: true)).isEmpty)
    }
}
