import Foundation
@testable import Lithe
import LitheCoreContracts
import Testing

/// The environment of a language server started by a runtime such as `node`:
/// commands the server runs by name must find the runtime the host selected.
struct LanguageToolEnvironmentTests {
    /// `/usr/bin/env node` resolves `node` by walking `PATH` and taking the
    /// first executable file of that name. This is the same walk, so the
    /// test does not need to start a process.
    private func resolve(_ command: String, in environment: [String: String]) -> URL? {
        (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func makeExecutable(_ name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test
    func aHelperStartedByNameRunsOnTheSelectedRuntimeInsteadOfAnOlderOneOnPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-tool-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let older = try makeExecutable("node", in: root.appendingPathComponent("older/bin"))
        let selected = try makeExecutable("node", in: root.appendingPathComponent("selected/bin"))
        let inherited = ["PATH": "\(older.deletingLastPathComponent().path):/usr/bin:/bin"]
        #expect(resolve("node", in: inherited) == older)

        let environment = LanguageToolEnvironment.exportingRuntime(
            tool: "node",
            executableURL: selected,
            into: inherited
        )

        #expect(resolve("node", in: environment) == selected)
        #expect(environment["LITHE_NODE_PATH"] == selected.path)
        // Everything else the server could already find stays reachable.
        #expect(environment["PATH"]?.hasSuffix(":/usr/bin:/bin") == true)
    }

    @Test
    func aRuntimeOutsideARestrictedPathBecomesFindableAndIsListedOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-tool-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try makeExecutable("node", in: root.appendingPathComponent("managed/bin"))
        let restricted = ["PATH": "/usr/bin:/bin"]
        #expect(resolve("node", in: restricted) == nil)

        let once = LanguageToolEnvironment.exportingRuntime(
            tool: "node", executableURL: selected, into: restricted
        )
        let twice = LanguageToolEnvironment.exportingRuntime(
            tool: "node", executableURL: selected, into: once
        )

        #expect(resolve("node", in: once) == selected)
        #expect(twice == once)
    }

    @Test
    func aMissingPathStillGetsTheRuntimeDirectory() {
        let environment = LanguageToolEnvironment.exportingRuntime(
            tool: "node",
            executableURL: URL(fileURLWithPath: "/opt/managed/bin/node"),
            into: [:]
        )

        #expect(environment["PATH"] == "/opt/managed/bin")
    }

    @Test
    func theRuntimeToolKeyMatchesWhatLaunchersRead() {
        #expect(LanguageToolEnvironment.runtimeToolKey("node") == "LITHE_NODE_PATH")
        #expect(LanguageToolEnvironment.runtimeToolKey("my-tool") == "LITHE_MY_TOOL_PATH")
    }

    /// The runtime launch names its tool even when the plugin declares no
    /// separate runtime dependency, which is the case `runtimeTools` misses.
    @Test
    func aRuntimeLaunchWithoutDependenciesStillNamesItsLaunchRuntime() throws {
        let manifest = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/node-runtime.plugin.json"))
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: manifest)
        let server = try #require(descriptor.languageServers.first)

        #expect(server.runtimeTools.isEmpty)
        #expect(server.launchRuntimeTool == "node")

        let java = try DeclarativePluginTestSupport.officialDescriptor("JavaSupport")
        #expect(java.languageServers.first?.launchRuntimeTool == "java")
        let php = try DeclarativePluginTestSupport.officialDescriptor("PhpSupport")
        #expect(php.languageServers.allSatisfy { $0.launchRuntimeTool == nil })
    }
}
