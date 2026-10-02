import Foundation
import LitheModuleAPI
import Testing
@testable import Lithe

struct MacPluginToolchainConfigurationTests {
    @Test
    func decodesAPluginDeclaredToolchainAndLanguageServerLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-toolchain-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("toolchain.json")
        try Data(
            """
            {
              "schemaVersion": 1,
              "pluginID": "dev.lithe.plugin.example-support",
              "toolchains": [{
                "id": "example-sdk",
                "kind": "sdk",
                "displayName": "Example SDK",
                "metadataURL": "https://example.com/releases.json",
                "indexFields": {
                  "stable": "stable", "files": "files", "filename": "filename",
                  "os": "os", "architecture": "arch", "version": "version",
                  "checksum": "sha256", "kind": "kind", "archiveKind": "archive"
                },
                "os": "darwin",
                "architecture": "host",
                "archiveFormat": "tar.gz",
                "archiveRoot": "toolchain",
                "executable": "bin/toolchain",
                "downloadURLTemplate": "https://example.com/releases/{filename}",
                "validationArguments": ["version"]
              }],
              "languageServers": [{
                "id": "example-server",
                "kind": "languageServer",
                "module": "example.org/language-server",
                "executable": "bin/language-server",
                "installCommand": ["install", "example.org/language-server@{version}"],
                "validationArguments": ["version"],
                "environment": {"TOOL_BIN": "{serverBin}"},
                "runtimeEnvironment": {"TOOLCHAIN_ROOT": "{toolchainRoot}"}
              }]
            }
            """.utf8
        ).write(to: manifestURL)

        let configuration = try MacPluginToolchainConfiguration.load(from: manifestURL)

        #expect(configuration.schemaVersion == 1)
        #expect(configuration.pluginID == PluginID("dev.lithe.plugin.example-support"))
        #expect(configuration.primaryToolchain?.executable == "bin/toolchain")
        #expect(configuration.primaryToolchain?.validationArguments == ["version"])
        #expect(configuration.primaryLanguageServer?.module == "example.org/language-server")
        #expect(configuration.discovery == nil)
    }

    @Test
    func expandsPluginDeclaredUserToolSearchPaths() {
        let paths = MacPluginToolchainManager.discoveryPaths(
            "{environment:TOOL_PATH}/bin",
            environment: ["TOOL_PATH": "/tmp/toolchain:/tmp/second"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )
        #expect(paths.map(\.path) == ["/tmp/toolchain/bin", "/tmp/second/bin"])
    }
}
