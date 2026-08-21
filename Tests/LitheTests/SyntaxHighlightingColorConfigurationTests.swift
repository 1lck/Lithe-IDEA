import AppKit
import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Syntax highlighting color configuration")
struct SyntaxHighlightingColorConfigurationTests {
    @Test
    func bundledColorsCoverEveryConfiguredFormat() {
        let formatIDs = Set(SyntaxHighlightingRegistry.bundled.formats.map(\.id))

        #expect(SyntaxHighlightingColorConfiguration.bundled.formatIDs == formatIDs)
    }

    @Test
    func formatOverridesResolveAdaptiveHexAndThemeColors() throws {
        let configuration = try SyntaxHighlightingColorConfiguration(data: Data(#"""
        {
          "version": 1,
          "defaults": {
            "text": "editor:text",
            "property": {"light": "#112233", "dark": "#445566CC"},
            "string": "theme:success"
          },
          "formats": {
            "json": {
              "property": {"light": "#ABCDEF", "dark": "#10203080"}
            }
          }
        }
        """#.utf8))
        let lightBase = CodeEditorPalette(isDark: false, theme: .lithe)
        let darkBase = CodeEditorPalette(isDark: true, theme: .lithe)
        let light = configuration.palette(formatID: "json", base: lightBase)
        let dark = configuration.palette(formatID: "json", base: darkBase)
        let fallback = configuration.palette(formatID: "yaml", base: lightBase)

        #expect(rgba(light.property) == [171, 205, 239, 255])
        #expect(rgba(dark.property) == [16, 32, 48, 128])
        #expect(rgba(fallback.property) == [17, 34, 51, 255])
        #expect(light.text == lightBase.text)
        #expect(light.string == LitheTheme.nsColor(.success, theme: .lithe, isDark: false))
    }

    @Test
    func invalidVersionsAndColorReferencesAreRejected() {
        let unsupportedVersion = Data(#"{"version":2,"defaults":{},"formats":{}}"#.utf8)
        let invalidReference = Data(#"""
        {
          "version": 1,
          "defaults": {"property": "#12345"},
          "formats": {}
        }
        """#.utf8)

        #expect(throws: SyntaxHighlightingColorConfigurationError.unsupportedVersion(2)) {
            try SyntaxHighlightingColorConfiguration(data: unsupportedVersion)
        }
        #expect(throws: SyntaxHighlightingColorConfigurationError.invalidColorReference(
            context: "defaults",
            role: "property",
            value: "#12345"
        )) {
            try SyntaxHighlightingColorConfiguration(data: invalidReference)
        }
    }

    private func rgba(_ color: NSColor) -> [Int] {
        guard let converted = color.usingColorSpace(.sRGB) else { return [] }
        return [
            Int((converted.redComponent * 255).rounded()),
            Int((converted.greenComponent * 255).rounded()),
            Int((converted.blueComponent * 255).rounded()),
            Int((converted.alphaComponent * 255).rounded())
        ]
    }
}
