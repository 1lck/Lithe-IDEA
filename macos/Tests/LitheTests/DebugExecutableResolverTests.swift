import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

/// The program a plugin's debug adapter launches: the plugin declares where to
/// look, Rust Core orders the candidates, and the host checks the file system.
/// Every case here reads the shared contract fixture through the real Core.
@Suite("Debug adapter executable lookup")
@MainActor
struct DebugExecutableResolverTests {
    private static let workspace = URL(fileURLWithPath: "/work/project", isDirectory: true)
    private static let sourceFile = "/work/project/src/app.c"
    private static let besideSource = "/work/project/src/app"
    private static let inBuildFolder = "/work/project/build/app"

    private func installedFixture() throws -> InstalledPluginPackage {
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/debug-adapter.plugin.json")
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: fixture)
        )
        return InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .marketplace
            ),
            packageURL: FileManager.default.temporaryDirectory
        )
    }

    private func resolver(
        settings: any PluginSettingsStoring = InMemoryPluginSettings(),
        runnable: Set<String> = []
    ) -> MacPluginDebugExecutableResolver {
        MacPluginDebugExecutableResolver(
            planner: DeclarativePluginTestSupport.operations,
            settings: settings,
            isRunnable: { runnable.contains($0) }
        )
    }

    private func adapter(_ id: String, in plugin: InstalledPluginPackage) throws -> DeclarativeDebugAdapter {
        try #require(plugin.descriptor.debugAdapters.first { $0.id == id })
    }

    /// Stores the program the way the settings page does: a project-scoped value.
    private func settings(program path: String, root: URL) throws -> MacPluginSettingsStore {
        let store = MacPluginSettingsStore(store: ExecutableLookupKeyValueStore())
        try store.setProjectValue(
            .string(path), forSetting: "program",
            plugin: "dev.lithe.fixture.debug-adapter", projectRoot: root
        )
        return store
    }

    @Test
    func theFirstCandidateThatCanRunWinsInTheOrderThePluginDeclared() throws {
        let plugin = try installedFixture()
        let native = try adapter("native", in: plugin)

        let both = try resolver(runnable: [Self.besideSource, Self.inBuildFolder])
            .lookup(plugin: plugin, adapterID: native.id, workspaceRootURL: Self.workspace, targetPath: Self.sourceFile)
        #expect(both == .found(path: Self.besideSource, isConfigured: false))

        let onlyBuild = try resolver(runnable: [Self.inBuildFolder])
            .lookup(plugin: plugin, adapterID: native.id, workspaceRootURL: Self.workspace, targetPath: Self.sourceFile)
        #expect(onlyBuild == .found(path: Self.inBuildFolder, isConfigured: false))
    }

    @Test
    func aNotFoundResultListsEveryPlaceThatWasChecked() throws {
        let plugin = try installedFixture()

        let lookup = try resolver()
            .lookup(plugin: plugin, adapterID: "native", workspaceRootURL: Self.workspace, targetPath: Self.sourceFile)

        #expect(lookup == .notFound(searched: [Self.besideSource, Self.inBuildFolder]))
    }

    @Test
    func withoutAnOpenFileTheCandidatesBuiltFromItAreLeftOut() throws {
        let plugin = try installedFixture()

        let lookup = try resolver(runnable: [Self.besideSource])
            .lookup(plugin: plugin, adapterID: "native", workspaceRootURL: Self.workspace, targetPath: nil)

        #expect(lookup == .notFound(searched: []))
    }

    @Test
    func theProgramTheUserChoseWinsEvenWhenACandidateExists() throws {
        let plugin = try installedFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-debug-executable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = root.appendingPathComponent("tools/mine").path
        let store = try settings(program: chosen, root: root)

        let lookup = try resolver(settings: store, runnable: [chosen, Self.besideSource])
            .lookup(plugin: plugin, adapterID: "native", workspaceRootURL: root, targetPath: Self.sourceFile)

        #expect(lookup == .found(path: chosen, isConfigured: true))
    }

    /// A chosen program that no longer runs is the user's problem to fix; quietly
    /// debugging another file would hide it.
    @Test
    func aChosenProgramThatCannotRunIsNeverReplacedByACandidate() throws {
        let plugin = try installedFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-debug-executable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = root.appendingPathComponent("gone").path
        let store = try settings(program: chosen, root: root)

        let found = try resolver(settings: store, runnable: [Self.besideSource])
            .lookup(plugin: plugin, adapterID: "native", workspaceRootURL: root, targetPath: Self.sourceFile)
        #expect(found == .configuredUnusable(path: chosen))

        #expect(throws: DebugLaunchConfigurationResolutionError.self) {
            try resolver(settings: store, runnable: [Self.besideSource]).executableForLaunch(
                plugin: plugin, adapter: try adapter("native", in: plugin),
                workspaceRootURL: root, targetPath: Self.sourceFile
            )
        }
    }

    @Test
    func anAdapterThatDeclaresNoLookupHasNothingToResolve() throws {
        let plugin = try installedFixture()
        let example = try adapter("example", in: plugin)

        #expect(example.launchExecutableSettingID == nil)
        #expect(try resolver().lookup(
            plugin: plugin, adapterID: "example", workspaceRootURL: Self.workspace, targetPath: Self.sourceFile
        ) == nil)
        #expect(try resolver().executableForLaunch(
            plugin: plugin, adapter: example, workspaceRootURL: Self.workspace, targetPath: Self.sourceFile
        ) == nil)
    }

    @Test
    func aLaunchGetsTheFoundProgramOrAnErrorThatNamesTheSetting() throws {
        let plugin = try installedFixture()
        let native = try adapter("native", in: plugin)
        #expect(native.launchExecutableSettingID == "program")

        let path = try resolver(runnable: [Self.inBuildFolder]).executableForLaunch(
            plugin: plugin, adapter: native, workspaceRootURL: Self.workspace, targetPath: Self.sourceFile
        )
        #expect(path == Self.inBuildFolder)

        do {
            _ = try resolver().executableForLaunch(
                plugin: plugin, adapter: native, workspaceRootURL: Self.workspace, targetPath: Self.sourceFile
            )
            Issue.record("A launch without a program must not start.")
        } catch let error as DebugLaunchConfigurationResolutionError {
            let message = try #require(error.errorDescription)
            // The user reads where to go: the setting's title and the places checked.
            #expect(message.contains("Program"))
            #expect(message.contains(Self.besideSource))
        }
    }

    @Test
    func aDirectoryIsNotAProgramTheDebuggerCanLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-debug-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = directory.appendingPathComponent("prog")
        try Data("#!/bin/sh\n".utf8).write(to: program)

        #expect(!MacPluginDebugExecutableResolver.isRunnableFile(directory.path))
        #expect(!MacPluginDebugExecutableResolver.isRunnableFile(program.path), "not executable yet")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        #expect(MacPluginDebugExecutableResolver.isRunnableFile(program.path))
        #expect(!MacPluginDebugExecutableResolver.isRunnableFile(directory.appendingPathComponent("missing").path))
    }

    @Test
    func theSettingsPageGetsTheLookupForTheSettingThatNamesTheProgram() throws {
        let plugin = try installedFixture()
        var asked: [(adapter: String, workspace: URL?, target: String?)] = []
        let manager = try makeManager(plugin: plugin) { _, adapterID, workspace, target in
            asked.append((adapterID, workspace, target))
            return .found(path: Self.besideSource, isConfigured: false)
        }
        manager.settingsProjectRootURL = Self.workspace
        manager.settingsActiveFileURL = URL(fileURLWithPath: Self.sourceFile)

        let snapshot = try #require(manager.snapshots.first { $0.id == plugin.descriptor.id })
        let program = try #require(snapshot.settings.first { $0.id == "program" })

        #expect(program.discovery == .found(path: Self.besideSource, isConfigured: false))
        // Only the adapter that declares a lookup is asked, with the open file as the target.
        #expect(asked.map(\.adapter) == ["native"])
        #expect(asked.first?.workspace == Self.workspace)
        #expect(asked.first?.target == Self.sourceFile)
    }

    @Test
    func aSettingThatIsNotAProgramShowsNoDiscovery() throws {
        let plugin = try installedFixture()
        let manager = try makeManager(plugin: plugin) { _, _, _, _ in nil }

        let snapshot = try #require(manager.snapshots.first { $0.id == plugin.descriptor.id })

        #expect(snapshot.settings.allSatisfy { $0.discovery == nil })
    }

    private func makeManager(
        plugin: InstalledPluginPackage,
        lookUp: @escaping MacPluginManager.DebugExecutableLookupHandler
    ) throws -> MacPluginManager {
        let configuration = MacModuleConfigurationStore(store: ExecutableLookupKeyValueStore())
        return MacPluginManager(
            packageStore: MacPluginPackageStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lithe-debug-executable-\(UUID().uuidString)", isDirectory: true),
                validator: DeclarativePluginTestSupport.operations
            ),
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: [plugin], registeredPlugins: [], issues: []),
            lookUpDebugExecutable: lookUp
        )
    }
}

private final class ExecutableLookupKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
