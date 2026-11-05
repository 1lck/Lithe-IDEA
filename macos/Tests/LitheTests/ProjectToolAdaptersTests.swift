import Foundation
import LitheCoreContracts
import LitheModuleAPI
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

        let found = try await finder.installations(of: ["python", "node"], sources: [Self.source(enabled: true)])

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

        let withoutEnabledPlugin = try await finder.installations(of: ["python"], sources: [Self.source(enabled: false)])
        let withoutTools = try await finder.installations(of: [], sources: [Self.source(enabled: true)])

        #expect(withoutEnabledPlugin.isEmpty)
        #expect(withoutTools.isEmpty)
        #expect(await log.requests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test
    func reportsAndThrowsWhenTheScratchDirectoryCannotBeCreated() async throws {
        let parent = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let log = DiscoveryLog()
        let events = TypedLogRecorder()
        let finder = MacProjectToolInstallations(
            discover: { request in
                await log.record(request)
                return Self.detection(of: "python", Self.python)
            },
            // The parent does not exist, so the scratch directory cannot be made.
            scratchParent: parent.appendingPathComponent("missing", isDirectory: true),
            report: { events.emit($0) }
        )

        // Not running discovery is not the same as finding nothing installed.
        await #expect(throws: (any Error).self) {
            try await finder.installations(of: ["python"], sources: [Self.source(enabled: true)])
        }
        #expect(await log.requests.isEmpty)
        #expect(Self.stages(events) == ["new-project-tools-scratch-create"])
    }

    @Test
    func reportsAScratchDirectoryItCouldNotRemove() async throws {
        let parent = try Self.temporaryDirectory()
        let locked = LockedValue<URL?>(nil)
        defer {
            // Make the directory removable again before cleaning up.
            if let directory = locked.value {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            }
            try? FileManager.default.removeItem(at: parent)
        }
        let events = TypedLogRecorder()
        let finder = MacProjectToolInstallations(
            discover: { request in
                // A read-only directory holding a file cannot be emptied.
                let directory = request.workspace.appendingPathComponent("locked", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                FileManager.default.createFile(atPath: directory.appendingPathComponent("file").path, contents: Data())
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
                locked.value = directory
                return Self.detection(of: "python", Self.python)
            },
            scratchParent: parent,
            report: { events.emit($0) }
        )

        let found = try await finder.installations(of: ["python"], sources: [Self.source(enabled: true)])

        // The listing is still right; the leftover directory is recorded.
        #expect(found == ["python": [Self.python]])
        #expect(Self.stages(events) == ["new-project-tools-scratch-remove"])
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

    /// The `stage` of each storage event the adapter reported, in order.
    private static func stages(_ recorder: TypedLogRecorder) -> [String] {
        recorder.events.compactMap { event in
            guard event is AppStorageMaintenanceFailed, case .token(let stage)? = event.fields["stage"] else {
                return nil
            }
            return stage
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-project-tool-adapters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A value the discovery stand-in sets off the main actor and the test reads.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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
