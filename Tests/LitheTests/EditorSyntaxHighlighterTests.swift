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

    @Test
    func yamlMappingKeysAndScalarValuesUseFormatSpecificColors() throws {
        let source = #"""
        ---
        service:
          port: 8080
          enabled: true
          endpoint: "https://example.test/#fragment" # public endpoint
          alias: &shared 0x10
          copied: *shared
          empty: null
        ...
        """#
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "YML",
            isDark: true
        )

        let text = source as NSString
        let keyColor = try color(in: storage, at: text.range(of: "port").location)
        let numberColor = try color(in: storage, at: text.range(of: "8080").location)
        let booleanColor = try color(in: storage, at: text.range(of: "true").location)
        let anchorColor = try color(in: storage, at: text.range(of: "&shared").location)
        let aliasColor = try color(in: storage, at: text.range(of: "*shared").location)
        let nullColor = try color(in: storage, at: text.range(of: "null").location)
        let markerColor = try color(in: storage, at: text.range(of: "---").location)

        #expect(keyColor != numberColor)
        #expect(numberColor != booleanColor)
        #expect(anchorColor == aliasColor)
        #expect(booleanColor == nullColor)
        #expect(markerColor == booleanColor)
    }

    @Test
    func yamlCommentsDoNotStartInsideQuotedOrUnseparatedScalarValues() throws {
        let source = #"""
        endpoint: "https://example.test/#fragment" # public endpoint
        identifier: release#42 # release marker
        """#
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "yaml",
            isDark: true
        )

        let text = source as NSString
        let stringColor = try color(in: storage, at: text.range(of: "#fragment").location)
        let unseparatedHashColor = try color(in: storage, at: text.range(of: "#42").location)
        let commentColor = try color(in: storage, at: text.range(of: "# public endpoint").location)
        let secondCommentColor = try color(in: storage, at: text.range(of: "# release marker").location)

        #expect(stringColor != commentColor)
        #expect(unseparatedHashColor != commentColor)
        #expect(commentColor == secondCommentColor)
    }

    private func color(in storage: NSTextStorage, at location: Int) throws -> NSColor {
        try #require(
            storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        )
    }
}
