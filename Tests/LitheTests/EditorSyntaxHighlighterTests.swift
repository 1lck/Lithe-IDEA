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
    func jsonSyntaxCorpusPreservesKeyAndValueTokenColors() throws {
        let source = try syntaxCorpus(named: "json-syntax-corpus", extension: "json")
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "json",
            isDark: true
        )

        let text = source as NSString
        let keyColor = try color(in: storage, at: text.range(of: #""name""#).location)
        let nestedKeyColor = try color(in: storage, at: text.range(of: #""nested""#).location)
        let escapedKeyColor = try color(in: storage, at: text.range(of: #""escaped\"key""#).location)
        let nestedNameRange = text.range(of: #""name": "nested-value""#)
        let nestedNameColor = try color(in: storage, at: nestedNameRange.location)
        let stringValueColor = try color(in: storage, at: text.range(of: #""Lithe""#).location)
        let numberValueColor = try color(in: storage, at: text.range(of: "42").location)
        let negativeNumberColor = try color(in: storage, at: text.range(of: "-3.14").location)
        let scientificNumberColor = try color(in: storage, at: text.range(of: "6.02e23").location)
        let urlFragmentColor = try color(in: storage, at: text.range(of: "#fragment").location)
        let booleanValueColor = try color(in: storage, at: text.range(of: "true").location)
        let nullTokenRange = text.range(of: #""nullValue": null"#)
        let nullValueColor = try color(in: storage, at: NSMaxRange(nullTokenRange) - "null".utf16.count)
        let repeatedStringColor = try color(in: storage, at: text.range(of: #""name""#, options: .backwards).location)
        #expect(keyColor == propertyColor)
        #expect(nestedKeyColor == propertyColor)
        #expect(escapedKeyColor == propertyColor)
        #expect(nestedNameColor == propertyColor)
        #expect(stringValueColor != propertyColor)
        #expect(numberValueColor != propertyColor)
        #expect(negativeNumberColor == numberValueColor)
        #expect(scientificNumberColor == numberValueColor)
        #expect(urlFragmentColor == stringValueColor)
        #expect(booleanValueColor != propertyColor)
        #expect(nullValueColor == booleanValueColor)
        #expect(repeatedStringColor == stringValueColor)
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

    @Test
    func yamlMappingKeysInsideQuotedScalarsRemainStringColored() throws {
        let source = #"""
        message: "hello, owner: admin"
        single: 'hello, owner: admin'
        flow: { owner: admin }
        """#
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "yaml",
            isDark: true
        )

        let text = source as NSString
        let doubleLine = text.range(of: #"message: "hello, owner: admin""#)
        let singleLine = text.range(of: "single: 'hello, owner: admin'")
        let flowLine = text.range(of: "flow: { owner: admin }")
        let doubleStringColor = try color(in: storage, at: doubleLine.location + "message: \"hello, ".utf16.count)
        let singleStringColor = try color(in: storage, at: singleLine.location + "single: 'hello, ".utf16.count)
        let flowPropertyColor = try color(in: storage, at: flowLine.location + "flow: { ".utf16.count)

        #expect(doubleStringColor == singleStringColor)
        #expect(doubleStringColor != flowPropertyColor)
        #expect(flowPropertyColor == propertyColor)
    }

    @Test
    func yamlBlockScalarStateIsRestoredBeforeIncrementalRange() throws {
        let source = #"""
        description: |
          first line
          number 123 remains literal text
        enabled: true
        """#
        let fullStorage = NSTextStorage(string: source)
        let incrementalStorage = NSTextStorage(string: source)
        let editedRange = (source as NSString).range(of: "number 123 remains literal text")

        SyntaxHighlighter.apply(
            to: fullStorage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "yaml",
            isDark: true
        )
        SyntaxHighlighter.apply(
            to: incrementalStorage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "yaml",
            isDark: true,
            range: editedRange
        )

        #expect(
            try color(in: incrementalStorage, at: editedRange.location)
                == color(in: fullStorage, at: editedRange.location)
        )
    }

    @Test
    func yamlIncrementalHighlightingUsesCachedLineStateNearDocumentEnd() {
        let source = String(repeating: "entry: value\n", count: 20_000) + "tail: true\n"
        let storage = NSTextStorage(string: source)
        let fullRange = NSRange(location: 0, length: storage.length)
        let palette = syntaxPalette(fileExtension: "yaml")
        YAMLSyntaxHighlightingAdapter.apply(to: storage, palette: palette, range: fullRange)
        let editedRange = (source as NSString).range(of: "tail: true")
        let target = SyntaxHighlighter.targetRange(
            for: editedRange,
            in: source as NSString,
            limit: fullRange
        )

        let scannedLineCount = YAMLSyntaxHighlightingAdapter.apply(
            to: storage,
            palette: palette,
            range: target
        )

        #expect(scannedLineCount < 10)
    }

    @Test
    func yamlSyntaxCorpusUsesExpectedTokenColors() throws {
        let source = try yamlSyntaxCorpus()
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "yaml",
            isDark: true
        )

        let text = source as NSString
        let propertyColor = try color(in: storage, at: text.range(of: "retry-count").location)
        let flowPropertyColor = try color(in: storage, at: text.range(of: "mode").location)
        let explicitPropertyColor = try color(in: storage, at: text.range(of: "explicit key").location)
        let keywordColor = try color(in: storage, at: text.range(of: "true").location)
        let directiveColor = try color(in: storage, at: text.range(of: "%YAML").location)
        let numberColor = try color(in: storage, at: text.range(of: "0xCAFE").location)
        let octalColor = try color(in: storage, at: text.range(of: "0o755").location)
        let binaryColor = try color(in: storage, at: text.range(of: "0b1010").location)
        let scientificColor = try color(in: storage, at: text.range(of: "-1.25e+3").location)
        let stringColor = try color(in: storage, at: text.range(of: "quoted # value").location)
        let quotedNumberColor = try color(in: storage, at: text.range(of: #""123""#).location + 1)
        let quotedKeywordColor = try color(in: storage, at: text.range(of: #""true""#).location + 1)
        let quotedAnchorColor = try color(in: storage, at: text.range(of: #""&foo""#).location + 1)
        let blockScalarColor = try color(in: storage, at: text.range(of: "number 123 remains literal text").location)
        let commentColor = try color(in: storage, at: text.range(of: "# item comment").location)
        let rootCommentColor = try color(in: storage, at: text.range(of: "# root comment").location)
        let anchorColor = try color(in: storage, at: text.range(of: "&defaults").location)
        let aliasColor = try color(in: storage, at: text.range(of: "*defaults").location)
        let tagColor = try color(in: storage, at: text.range(of: "!e!service").location)
        let quotedHashColor = try color(in: storage, at: text.range(of: "# not a comment").location)
        let unseparatedHashColor = try color(in: storage, at: text.range(of: "#42").location)
        let nullColor = try color(in: storage, at: text.range(of: "null").location)
        let tildeColor = try color(in: storage, at: text.range(of: "~").location)
        let documentEndColor = try color(in: storage, at: text.range(of: "...").location)
        #expect(propertyColor == self.propertyColor)
        #expect(flowPropertyColor == self.propertyColor)
        #expect(explicitPropertyColor == self.propertyColor)
        #expect(keywordColor == directiveColor)
        #expect(nullColor == keywordColor)
        #expect(tildeColor == keywordColor)
        #expect(documentEndColor == keywordColor)
        #expect(numberColor == octalColor)
        #expect(octalColor == binaryColor)
        #expect(binaryColor == scientificColor)
        #expect(stringColor == blockScalarColor)
        #expect(quotedNumberColor == stringColor)
        #expect(quotedKeywordColor == stringColor)
        #expect(quotedAnchorColor == stringColor)
        #expect(commentColor == rootCommentColor)
        #expect(anchorColor == aliasColor)
        #expect(aliasColor == tagColor)
        #expect(quotedHashColor == stringColor)
        #expect(unseparatedHashColor != commentColor)
    }

    @Test
    func iniSyntaxCorpusUsesExpectedTokenColors() throws {
        let source = try syntaxCorpus(named: "ini-syntax-corpus", extension: "ini")
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "ini",
            isDark: true
        )

        let text = source as NSString
        let sectionColor = try color(in: storage, at: text.range(of: "server.production").location)
        let propertyColor = try color(in: storage, at: text.range(of: "port").location)
        let stringColor = try color(in: storage, at: text.range(of: "example.test").location)
        let numberColor = try color(in: storage, at: text.range(of: "8443").location)
        let booleanColor = try color(in: storage, at: text.range(of: "true").location)
        let quotedHashColor = try color(in: storage, at: text.range(of: "# path").location)
        let quotedNumberColor = try color(in: storage, at: text.range(of: "123").location)
        let unseparatedHashColor = try color(in: storage, at: text.range(of: "#42").location)
        let commentColor = try color(in: storage, at: text.range(of: "; HTTPS port").location)
        let rootCommentColor = try color(in: storage, at: text.range(of: "; root comment").location)

        #expect(propertyColor == self.propertyColor)
        #expect(sectionColor != propertyColor)
        #expect(stringColor != propertyColor)
        #expect(numberColor != propertyColor)
        #expect(booleanColor != propertyColor)
        #expect(quotedHashColor == stringColor)
        #expect(quotedNumberColor == stringColor)
        #expect(unseparatedHashColor == stringColor)
        #expect(commentColor == rootCommentColor)
    }

    @Test
    func xmlSyntaxCorpusUsesExpectedTokenColors() throws {
        let source = try syntaxCorpus(named: "xml-syntax-corpus", extension: "xml")
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "xml",
            isDark: true
        )

        let text = source as NSString
        let declarationColor = try color(in: storage, at: text.range(of: "<?xml").location)
        let tagColor = try color(in: storage, at: text.range(of: "services").location)
        let nestedTagRange = text.range(of: #"<service id="gateway""#)
        let nestedTagColor = try color(in: storage, at: nestedTagRange.location + 1)
        let attributeColor = try color(in: storage, at: text.range(of: "environment").location)
        let stringColor = try color(in: storage, at: text.range(of: "example.test").location)
        let fragmentColor = try color(in: storage, at: text.range(of: "#fragment").location)
        let cdataColor = try color(in: storage, at: text.range(of: "candidate").location)
        let commentColor = try color(in: storage, at: text.range(of: "service configuration").location)

        #expect(tagColor == nestedTagColor)
        #expect(attributeColor == propertyColor)
        #expect(stringColor == fragmentColor)
        #expect(cdataColor == stringColor)
        #expect(declarationColor != tagColor)
        #expect(commentColor != tagColor)
        #expect(commentColor != stringColor)
    }

    @Test
    func xmlAttributesAreOnlyHighlightedInsideStartTags() throws {
        let source = #"""
        text attr = "not-an-attribute"
        <!-- <fake attr="comment"> -->
        <root
          real="value"
          enabled = "true">
          body attr = "still-not-an-attribute"
        </root>
        """#
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "xml",
            isDark: true
        )

        let text = source as NSString
        let palette = syntaxPalette(fileExtension: "xml")
        let outsideAttribute = try color(in: storage, at: text.range(of: "attr").location)
        let outsideValue = try color(in: storage, at: text.range(of: "not-an-attribute").location)
        let commentAttribute = try color(in: storage, at: text.range(of: "fake attr").location + "fake ".utf16.count)
        let realAttribute = try color(in: storage, at: text.range(of: "real").location)
        let realValue = try color(in: storage, at: text.range(of: #""value""#).location)
        let enabledAttribute = try color(in: storage, at: text.range(of: "enabled").location)
        let enabledValue = try color(in: storage, at: text.range(of: #""true""#).location)
        let bodyAttribute = try color(in: storage, at: text.range(of: "body attr").location + "body ".utf16.count)
        let bodyValue = try color(in: storage, at: text.range(of: "still-not-an-attribute").location)

        #expect(outsideAttribute == palette.text)
        #expect(outsideValue == palette.text)
        #expect(commentAttribute == palette.comment)
        #expect(realAttribute == palette.property)
        #expect(realValue == palette.string)
        #expect(enabledAttribute == palette.property)
        #expect(enabledValue == palette.string)
        #expect(bodyAttribute == palette.text)
        #expect(bodyValue == palette.text)
    }

    @Test
    func tomlSyntaxCorpusUsesExpectedTokenColors() throws {
        let source = try syntaxCorpus(named: "toml-syntax-corpus", extension: "toml")
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "toml",
            isDark: true
        )

        let text = source as NSString
        let propertyColor = try color(in: storage, at: text.range(of: "title").location)
        let quotedPropertyColor = try color(in: storage, at: text.range(of: #""quoted"."key""#).location)
        let inlinePropertyColor = try color(in: storage, at: text.range(of: "owner").location)
        let tableColor = try color(in: storage, at: text.range(of: "server.production").location)
        let arrayTableColor = try color(in: storage, at: text.range(of: "products").location)
        let stringColor = try color(in: storage, at: text.range(of: "Lithe # not a comment").location)
        let multilineStringColor = try color(in: storage, at: text.range(of: "number 123 remains string text").location)
        let numberColor = try color(in: storage, at: text.range(of: "8443").location)
        let dateColor = try color(in: storage, at: text.range(of: "2026-08-19").location)
        let booleanColor = try color(in: storage, at: text.range(of: "true").location)
        let commentColor = try color(in: storage, at: text.range(of: "# inline comment").location)
        let rootCommentColor = try color(in: storage, at: text.range(of: "# root comment").location)
        let quotedHashColor = try color(in: storage, at: text.range(of: "# not a comment").location)

        #expect(propertyColor == self.propertyColor)
        #expect(quotedPropertyColor == propertyColor)
        #expect(inlinePropertyColor == propertyColor)
        #expect(tableColor != propertyColor)
        #expect(arrayTableColor == tableColor)
        #expect(stringColor == multilineStringColor)
        #expect(numberColor == dateColor)
        #expect(booleanColor != propertyColor)
        #expect(commentColor == rootCommentColor)
        #expect(quotedHashColor == stringColor)
    }

    @Test
    func tomlInlinePropertiesDoNotOverrideStringTokens() throws {
        let source = """
        message = "hello, owner = admin"
        literal = '''
        hello, owner = admin
        '''
        inline = { owner = "Tom" }
        """
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "toml",
            isDark: true
        )

        let text = source as NSString
        let quotedLine = text.range(of: #"message = "hello, owner = admin""#)
        let multilineLine = text.range(of: "hello, owner = admin", options: .backwards)
        let inlineLine = text.range(of: #"inline = { owner = "Tom" }"#)
        let quotedOwnerColor = try color(in: storage, at: quotedLine.location + "message = \"hello, ".utf16.count)
        let multilineOwnerColor = try color(in: storage, at: multilineLine.location + "hello, ".utf16.count)
        let inlineOwnerColor = try color(in: storage, at: inlineLine.location + "inline = { ".utf16.count)

        #expect(quotedOwnerColor == multilineOwnerColor)
        #expect(quotedOwnerColor != inlineOwnerColor)
        #expect(inlineOwnerColor == propertyColor)
    }

    @Test
    func tomlMultilineStringKeepsItsColorDuringIncrementalHighlighting() throws {
        let source = try syntaxCorpus(named: "toml-syntax-corpus", extension: "toml")
        let fullStorage = NSTextStorage(string: source)
        let incrementalStorage = NSTextStorage(string: source)
        let text = source as NSString
        let editedRange = text.range(of: "number 123 remains string text")

        SyntaxHighlighter.apply(
            to: fullStorage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "toml",
            isDark: true
        )
        SyntaxHighlighter.apply(
            to: incrementalStorage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "toml",
            isDark: true,
            range: editedRange
        )

        let expectedColor = try color(in: fullStorage, at: editedRange.location)
        let incrementalColor = try color(in: incrementalStorage, at: editedRange.location)
        #expect(incrementalColor == expectedColor)
    }

    @Test
    func tomlIncrementalHighlightingUsesCachedLineStateNearDocumentEnd() {
        let source = String(repeating: "entry = \"value\"\n", count: 20_000) + "tail = true\n"
        let storage = NSTextStorage(string: source)
        let fullRange = NSRange(location: 0, length: storage.length)
        let palette = syntaxPalette(fileExtension: "toml")
        TOMLSyntaxHighlightingAdapter.apply(to: storage, palette: palette, range: fullRange)
        let editedRange = (source as NSString).range(of: "tail = true")
        let target = SyntaxHighlighter.targetRange(
            for: editedRange,
            in: source as NSString,
            limit: fullRange
        )

        let scannedLineCount = TOMLSyntaxHighlightingAdapter.apply(
            to: storage,
            palette: palette,
            range: target
        )

        #expect(scannedLineCount < 10)
    }

    @Test
    func envSyntaxCorpusUsesExpectedTokenColors() throws {
        let source = try syntaxCorpus(named: "env-syntax-corpus", extension: "env")
        let storage = NSTextStorage(string: source)
        let fileURL = URL(fileURLWithPath: ".env.local")

        SyntaxHighlighter.apply(
            to: storage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileName: fileURL.lastPathComponent,
            fileExtension: fileURL.pathExtension,
            isDark: true
        )

        let text = source as NSString
        let keyColor = try color(in: storage, at: text.range(of: "APP_NAME").location)
        let stringColor = try color(in: storage, at: text.range(of: "Lithe").location)
        let numberColor = try color(in: storage, at: text.range(of: "8443").location)
        let booleanColor = try color(in: storage, at: text.range(of: "true").location)
        let variableColor = try color(in: storage, at: text.range(of: "${HOME}").location)
        let commentColor = try color(in: storage, at: text.range(of: "# root comment").location)
        let quotedHashColor = try color(in: storage, at: text.range(of: "# remains a string").location)
        let inlineCommentColor = try color(in: storage, at: text.range(of: "# inline comment").location)

        #expect(keyColor == propertyColor)
        #expect(stringColor != keyColor)
        #expect(numberColor != stringColor)
        #expect(booleanColor != stringColor)
        #expect(variableColor != stringColor)
        #expect(commentColor == inlineCommentColor)
        #expect(quotedHashColor == stringColor)
    }

    @Test
    func propertiesSyntaxCorpusUsesExpectedTokenColors() throws {
        let source = try syntaxCorpus(named: "properties-syntax-corpus", extension: "properties")
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(to: storage, font: .monospacedSystemFont(ofSize: 13, weight: .regular), fileExtension: "properties", isDark: true)

        let text = source as NSString
        let keyColor = try color(in: storage, at: text.range(of: "app.name").location)
        let colonKeyColor = try color(in: storage, at: text.range(of: "server.port").location)
        let stringColor = try color(in: storage, at: text.range(of: "Lithe").location)
        let numberColor = try color(in: storage, at: text.range(of: "8443").location)
        let booleanColor = try color(in: storage, at: text.range(of: "true").location)
        let continuationColor = try color(in: storage, at: text.range(of: "second line").location)
        let commentColor = try color(in: storage, at: text.range(of: "# root comment").location)
        let legacyCommentColor = try color(in: storage, at: text.range(of: "! legacy comment").location)
        let quotedHashColor = try color(in: storage, at: text.range(of: "# remains a string").location)
        let spacedSeparatorRange = text.range(of: "spaced.value = 8081")
        let spacedSeparatorColor = try color(
            in: storage,
            at: spacedSeparatorRange.location + "spaced.value ".utf16.count
        )

        #expect(keyColor == propertyColor)
        #expect(colonKeyColor == propertyColor)
        #expect(stringColor != keyColor)
        #expect(numberColor != stringColor)
        #expect(booleanColor != stringColor)
        #expect(continuationColor == stringColor)
        #expect(commentColor == legacyCommentColor)
        #expect(quotedHashColor == stringColor)
        #expect(spacedSeparatorColor != stringColor)
        #expect(spacedSeparatorColor != keyColor)
    }

    @Test
    func propertiesIncrementalHighlightingPreservesContinuationState() throws {
        let source = [
            "continued=first line \\",
            "  second line \\",
            "  third line",
            "next=true"
        ].joined(separator: "\n") + "\n"
        let fullStorage = NSTextStorage(string: source)
        let incrementalStorage = NSTextStorage(string: source)
        let text = source as NSString
        let editedRange = text.range(of: "third line")

        SyntaxHighlighter.apply(
            to: fullStorage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "properties",
            isDark: true
        )
        SyntaxHighlighter.apply(
            to: incrementalStorage,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            fileExtension: "properties",
            isDark: true,
            range: editedRange
        )

        let expectedColor = try color(in: fullStorage, at: editedRange.location)
        let incrementalColor = try color(in: incrementalStorage, at: editedRange.location)

        #expect(incrementalColor == expectedColor)
        #expect(incrementalColor == syntaxPalette(fileExtension: "properties").string)
    }

    @Test
    func configSyntaxCorpusUsesExpectedTokenColors() throws {
        let source = try syntaxCorpus(named: "config-syntax-corpus", extension: "conf")
        let storage = NSTextStorage(string: source)

        SyntaxHighlighter.apply(to: storage, font: .monospacedSystemFont(ofSize: 13, weight: .regular), fileExtension: "conf", isDark: true)

        let text = source as NSString
        let sectionColor = try color(in: storage, at: text.range(of: "server.production").location)
        let keyColor = try color(in: storage, at: text.range(of: "host").location)
        let stringColor = try color(in: storage, at: text.range(of: "example.test").location)
        let numberColor = try color(in: storage, at: text.range(of: "8443").location)
        let booleanColor = try color(in: storage, at: text.range(of: "on").location)
        let hexColor = try color(in: storage, at: text.range(of: "0xCAFE").location)
        let quotedHashColor = try color(in: storage, at: text.range(of: "# remains a string").location)
        let commentColor = try color(in: storage, at: text.range(of: "# root comment").location)
        let semicolonCommentColor = try color(in: storage, at: text.range(of: "; port comment").location)
        let separatorRange = text.range(of: #"host = "example.test""#)
        let separatorColor = try color(in: storage, at: separatorRange.location + "host ".utf16.count)

        #expect(sectionColor != keyColor)
        #expect(keyColor == propertyColor)
        #expect(stringColor != keyColor)
        #expect(numberColor != stringColor)
        #expect(booleanColor != stringColor)
        #expect(hexColor != stringColor)
        #expect(quotedHashColor == stringColor)
        #expect(commentColor == semicolonCommentColor)
        #expect(separatorColor != stringColor)
        #expect(separatorColor != keyColor)
    }

    private func yamlSyntaxCorpus() throws -> String {
        try syntaxCorpus(named: "yaml-syntax-corpus", extension: "yaml")
    }

    private func syntaxCorpus(named name: String, extension fileExtension: String) throws -> String {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Fixtures/SyntaxHighlighting"
            )
        )
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }

    private var propertyColor: NSColor {
        NSColor(srgbRed: 79 / 255, green: 148 / 255, blue: 250 / 255, alpha: 1)
    }

    private func syntaxPalette(fileExtension: String) -> SyntaxHighlightingPalette {
        let basePalette = CodeEditorPalette(isDark: true, theme: LitheTheme.activeTheme)
        let format = SyntaxHighlightingRegistry.bundled.format(
            fileName: nil,
            fileExtension: fileExtension
        )
        return SyntaxHighlightingColorConfiguration.bundled.palette(
            formatID: format?.id,
            base: basePalette
        )
    }

    private func color(in storage: NSTextStorage, at location: Int) throws -> NSColor {
        try #require(
            storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        )
    }
}
