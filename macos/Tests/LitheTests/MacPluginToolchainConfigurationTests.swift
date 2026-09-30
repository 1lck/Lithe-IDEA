import Foundation
import LitheModuleAPI
import Testing
@testable import Lithe

struct MacPluginToolchainConfigurationTests {
    @Test
    func decodesDeclarativeGoSDKAndGoplsLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-toolchain-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("toolchain.json")
        try Data(
            """
            {
              "schemaVersion": 1,
              "pluginID": "dev.lithe.plugin.go-support",
              "toolchains": [{
                "id": "go-sdk",
                "kind": "sdk",
                "displayName": "Go SDK",
                "metadataURL": "https://go.dev/dl/?mode=json&include=all",
                "indexFields": {
                  "stable": "stable", "files": "files", "filename": "filename",
                  "os": "os", "architecture": "arch", "version": "version",
                  "checksum": "sha256", "kind": "kind", "archiveKind": "archive"
                },
                "os": "darwin",
                "architecture": "host",
                "archiveFormat": "tar.gz",
                "archiveRoot": "go",
                "executable": "bin/go",
                "downloadURLTemplate": "https://go.dev/dl/{filename}",
                "validationArguments": ["version"]
              }],
              "languageServers": [{
                "id": "gopls",
                "kind": "goModule",
                "module": "golang.org/x/tools/gopls",
                "executable": "bin/gopls",
                "installCommand": ["install", "golang.org/x/tools/gopls@{version}"],
                "validationArguments": ["version"],
                "environment": {"GOBIN": "{serverBin}"},
                "runtimeEnvironment": {"GOROOT": "{toolchainRoot}"}
              }]
            }
            """.utf8
        ).write(to: manifestURL)

        let configuration = try MacPluginToolchainConfiguration.load(from: manifestURL)

        #expect(configuration.schemaVersion == 1)
        #expect(configuration.pluginID == PluginID("dev.lithe.plugin.go-support"))
        #expect(configuration.primaryToolchain?.executable == "bin/go")
        #expect(configuration.primaryToolchain?.validationArguments == ["version"])
        #expect(configuration.primaryLanguageServer?.module == "golang.org/x/tools/gopls")
        #expect(configuration.discovery == nil)
    }

    @Test
    func expandsPluginDeclaredUserToolSearchPaths() {
        let paths = MacPluginToolchainManager.discoveryPaths(
            "{environment:GOPATH}/bin",
            environment: ["GOPATH": "/tmp/go:/tmp/second"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )
        #expect(paths.map(\.path) == ["/tmp/go/bin", "/tmp/second/bin"])
    }
}
