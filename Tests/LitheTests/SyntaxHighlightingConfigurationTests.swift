import Foundation
import Testing
@testable import Lithe

@Suite("Syntax highlighting configuration")
struct SyntaxHighlightingConfigurationTests {
    @Test
    func bundledMappingRegistersPlannedConfigurationFormats() {
        let registry = SyntaxHighlightingRegistry.bundled
        let expectedFormatsByExtension = [
            "properties": "properties",
            "yml": "yaml",
            "yaml": "yaml",
            "json": "json",
            "toml": "toml",
            "ini": "ini",
            "xml": "xml",
            "conf": "generic-config",
            "config": "generic-config"
        ]

        for (fileExtension, formatID) in expectedFormatsByExtension {
            #expect(registry.format(fileExtension: fileExtension)?.id == formatID)
        }
        #expect(registry.adapter(fileExtension: "json") == .json)
        #expect(registry.adapter(fileExtension: "yaml") == .generic)
    }

    @Test
    func fileMatchingNormalizesCaseAndLeadingDots() {
        let registry = SyntaxHighlightingRegistry.bundled

        #expect(registry.format(fileExtension: ".JSON")?.id == "json")
        #expect(registry.format(fileName: ".ENV", fileExtension: "")?.id == "env")
        #expect(registry.format(fileName: ".env.LOCAL", fileExtension: "local")?.id == "env")
    }

    @Test
    func exactFileNameAndPrefixTakePriorityOverExtension() throws {
        let registry = try SyntaxHighlightingRegistry(data: Data(#"""
        {
          "version": 1,
          "formats": [
            {
              "id": "extension-match",
              "displayName": "Extension Match",
              "fileExtensions": ["local"],
              "adapter": "json"
            },
            {
              "id": "name-match",
              "displayName": "Name Match",
              "fileNames": ["settings.local"],
              "fileNamePrefixes": [".env."],
              "adapter": "generic"
            }
          ]
        }
        """#.utf8))

        #expect(registry.format(fileName: "settings.local", fileExtension: "local")?.id == "name-match")
        #expect(registry.format(fileName: ".env.local", fileExtension: "local")?.id == "name-match")
    }

    @Test
    func mappingCanRouteAnAdditionalExtensionToAnExistingAdapter() throws {
        let registry = try SyntaxHighlightingRegistry(data: Data(#"""
        {
          "version": 1,
          "formats": [
            {
              "id": "json-compatible",
              "displayName": "JSON Compatible",
              "fileExtensions": ["json5"],
              "adapter": "json"
            }
          ]
        }
        """#.utf8))

        #expect(registry.adapter(fileExtension: "json5") == .json)
        #expect(registry.adapter(fileExtension: "unknown") == .generic)
    }

    @Test
    func unsupportedVersionsAndConflictingMatchersAreRejected() {
        let unsupportedVersion = Data(#"{"version":2,"formats":[]}"#.utf8)
        let duplicateExtension = Data(#"""
        {
          "version": 1,
          "formats": [
            {
              "id": "first",
              "displayName": "First",
              "fileExtensions": ["json"],
              "adapter": "json"
            },
            {
              "id": "second",
              "displayName": "Second",
              "fileExtensions": [".JSON"],
              "adapter": "generic"
            }
          ]
        }
        """#.utf8)

        #expect(throws: SyntaxHighlightingConfigurationError.unsupportedVersion(2)) {
            try SyntaxHighlightingRegistry(data: unsupportedVersion)
        }
        #expect(throws: SyntaxHighlightingConfigurationError.duplicateFileExtension("json")) {
            try SyntaxHighlightingRegistry(data: duplicateExtension)
        }
    }
}
