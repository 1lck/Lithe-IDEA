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
            "cfg": "ini",
            "cnf": "ini",
            "xml": "xml",
            "conf": "generic-config",
            "config": "generic-config",
            "env": "env"
        ]

        for (fileExtension, formatID) in expectedFormatsByExtension {
            #expect(registry.format(fileExtension: fileExtension)?.id == formatID)
        }
        #expect(registry.adapter(fileExtension: "ini") == .ini)
        #expect(registry.adapter(fileExtension: "json") == .json)
        #expect(registry.adapter(fileExtension: "properties") == .properties)
        #expect(registry.adapter(fileExtension: "toml") == .toml)
        #expect(registry.adapter(fileExtension: "xml") == .xml)
        #expect(registry.adapter(fileExtension: "yaml") == .yaml)
        #expect(registry.adapter(fileExtension: "conf") == .config)
        #expect(registry.adapter(fileExtension: "config") == .config)
    }

    @Test
    func fileMatchingNormalizesCaseAndLeadingDots() {
        let registry = SyntaxHighlightingRegistry.bundled

        #expect(registry.format(fileExtension: ".JSON")?.id == "json")
        #expect(registry.format(fileName: ".ENV", fileExtension: "")?.id == "env")
        #expect(registry.format(fileName: ".env.LOCAL", fileExtension: "local")?.id == "env")
        #expect(registry.adapter(fileName: ".env", fileExtension: "") == .envFile)
        #expect(registry.adapter(fileName: "credentials.env", fileExtension: ".ENV") == .envFile)
    }

    @Test
    func commonEnvironmentFileNamesUseEnvironmentAdapter() {
        let registry = SyntaxHighlightingRegistry.bundled
        let environmentFileNames = [
            ".env",
            ".env.local",
            ".env.development",
            ".env.development.local",
            ".env.test",
            ".env.test.local",
            ".env.production",
            ".env.production.local",
            ".env.staging",
            ".env.staging.local",
            ".env.example",
            ".env.sample",
            ".env.template",
            "credentials.env"
        ]

        for fileName in environmentFileNames {
            let fileURL = URL(fileURLWithPath: fileName)
            #expect(
                registry.adapter(
                    fileName: fileURL.lastPathComponent,
                    fileExtension: fileURL.pathExtension
                ) == .envFile
            )
        }

        #expect(registry.adapter(fileName: ".environment", fileExtension: "") == .generic)
        #expect(registry.adapter(fileName: "env.local", fileExtension: "local") == .generic)
    }

    @Test
    func commonExtensionlessConfigurationFilesUseINIAdapter() {
        let registry = SyntaxHighlightingRegistry.bundled

        #expect(registry.adapter(fileName: ".gitconfig", fileExtension: "") == .ini)
        #expect(registry.adapter(fileName: ".editorconfig", fileExtension: "") == .ini)
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
