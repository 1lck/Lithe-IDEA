import AppKit
import Testing
@testable import Lithe

@MainActor
@Suite("Editor syntax highlighting")
struct EditorSyntaxHighlighterTests {
    @Test
    func jsonPropertyKeysUseADifferentColorFromStringValues() throws {
        let source = #"{"name":"Lithe","nested":{"escaped\"key":"name"}}"#
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "JSON",
            isDark: true
        )

        let text = source as NSString
        let keyRange = text.range(of: #""name""#)
        let valueRange = text.range(of: #""Lithe""#)
        let repeatedValueRange = text.range(of: #""name""#, options: .backwards)
        let keyColor = try #require(
            storage.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor
        )
        let valueColor = try #require(
            storage.attribute(.foregroundColor, at: valueRange.location, effectiveRange: nil) as? NSColor
        )
        let repeatedValueColor = try #require(
            storage.attribute(.foregroundColor, at: repeatedValueRange.location, effectiveRange: nil) as? NSColor
        )

        #expect(keyColor != valueColor)
        #expect(repeatedValueColor == valueColor)
    }

    @Test
    func nonJSONQuotedLabelsRemainStringColored() throws {
        let source = #"{"name":"Lithe"}"#
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "swift",
            isDark: true
        )

        let text = source as NSString
        let keyRange = text.range(of: #""name""#)
        let valueRange = text.range(of: #""Lithe""#)
        let keyColor = try #require(
            storage.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor
        )
        let valueColor = try #require(
            storage.attribute(.foregroundColor, at: valueRange.location, effectiveRange: nil) as? NSColor
        )

        #expect(keyColor == valueColor)
    }
}
