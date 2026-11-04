import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// The two macOS adapters behind a New Project `tool` field: finding the
/// installations to offer, and recording the chosen one in the new project.
@Suite("New project tool adapters")
@MainActor
struct ProjectToolAdaptersTests {
    // The discovery stand-in below runs off the main actor and reads these.
    nonisolated private static let python = ProjectToolInstallation(
        home: "/opt/python-3.12", executable: "/opt/python-3.12/bin/python3", version: "3.12.4"
    )

    // MARK: Finding installations

    @Test
    func discoversInAnEmptyScratchDirectoryAndRemovesIt() async throws {
        let parent = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let log = DiscoveryLog()
        let finder = MacProjectToolInstallations(
            discover: { request in
                await log.record(request)
                return Self.detection(of: "python", Self.python)
            },
            environment: { ["PATH": "/usr/bin"] },
            scratchParent: parent
        )

        let found = await finder.installations(of: ["python", "node"], sources: [Self.source(enabled: true)])

        // A tool with nothing installed is listed with no installations.
        #expect(found == ["python": [Self.python], "node": []])
        let request = try #require(await log.requests.first)
        #expect(request.environment == ["PATH": "/usr/bin"])
        #expect(request.sources.map(\.pluginID) == ["dev.example.tools"])
        // Discovery ran in a new, empty directory below the given parent, ...
        #expect(request.workspace.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
        #expect(await log.scratchDirectoriesWereEmpty == [true])
        // ... and nothing of it is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test
    func doesNotRunDiscoveryWithoutEnabledPluginsOrTools() async throws {
        let parent = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let log = DiscoveryLog()
        let finder = MacProjectToolInstallations(
            discover: { request in
                await log.record(request)
                return MacToolchainDiscovery.Result()
            },
            scratchParent: parent
        )

        let withoutEnabledPlugin = await finder.installations(of: ["python"], sources: [Self.source(enabled: false)])
        let withoutTools = await finder.installations(of: [], sources: [Self.source(enabled: true)])

        #expect(withoutEnabledPlugin.isEmpty)
        #expect(withoutTools.isEmpty)
        #expect(await log.requests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    // MARK: Pinning

    @Test
    func pinsTheChosenInstallationAsTheProjectDefault() async throws {
        let project = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let store = Self.store()
        let pin = Self.pin(tool: "dev.example.tools:python", Self.python)

        try await MacProjectToolPins.save(pin, in: project, using: store)

        let snapshot = try await store.load(workspace: project)
        let address = ToolchainPreferenceAddress(directory: ".", consumer: nil, tool: pin.tool)
        #expect(try store.inspect(address, snapshot: snapshot).fixed == .installation(home: Self.python.home))
        // It is the document the Toolchains settings page edits, not a new store.
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(".lithe/run/local.json").path))
    }

    @Test
    func pinningAnotherToolKeepsThePinsAlreadySaved() async throws {
        let project = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let store = Self.store()
        let node = ProjectToolInstallation(home: "/opt/node-22", executable: "/opt/node-22/bin/node", version: "22.11.0")
        let pins = [Self.pin(tool: "dev.example.tools:python", Self.python), Self.pin(tool: "dev.example.tools:node", node)]

        for pin in pins { try await MacProjectToolPins.save(pin, in: project, using: store) }

        let snapshot = try await store.load(workspace: project)
        for (pin, installation) in zip(pins, [Self.python, node]) {
            let address = ToolchainPreferenceAddress(directory: ".", consumer: nil, tool: pin.tool)
            #expect(try store.inspect(address, snapshot: snapshot).fixed == .installation(home: installation.home))
        }
    }

    // MARK: Helpers

    private static func source(enabled: Bool) -> ToolchainSettingsPluginSource {
        ToolchainSettingsPluginSource(
            pluginID: "dev.example.tools", name: "Example tools", manifest: Data("{}".utf8), isEnabled: enabled
        )
    }

    nonisolated private static func detection(
        of tool: String, _ installation: ProjectToolInstallation
    ) -> MacToolchainDiscovery.Result {
        MacToolchainDiscovery.Result(detections: [
            tool: .init(installations: [
                .init(
                    home: installation.home, executable: installation.executable,
                    version: installation.version, provider: "host:system"
                )
            ])
        ])
    }

    private static func pin(tool: String, _ installation: ProjectToolInstallation) -> ProjectGenerationPlan.ToolPin {
        ProjectGenerationPlan.ToolPin(
            field: "sdk", tool: tool, pinAs: "project", home: installation.home, executable: installation.executable
        )
    }

    private static func store() -> MacToolchainPreferencesStore {
        MacToolchainPreferencesStore(core: RustCoreBridge(), storage: MacFileStorage(), immutableRoots: { [] })
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-project-tool-adapters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Stands in for toolchain discovery: remembers each request and whether the
/// directory it was asked to look in was empty at that moment.
private actor DiscoveryLog {
    private(set) var requests: [MacToolchainDiscovery.Request] = []
    private(set) var scratchDirectoriesWereEmpty: [Bool] = []

    func record(_ request: MacToolchainDiscovery.Request) {
        requests.append(request)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: request.workspace.path)
        scratchDirectoriesWereEmpty.append(contents?.isEmpty == true)
    }
}
