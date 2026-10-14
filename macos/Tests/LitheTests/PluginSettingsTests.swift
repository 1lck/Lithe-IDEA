import Foundation
@testable import Lithe
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import Testing

/// User-adjustable options of declarative plugins: where the values live, how
/// the plugin page presents them, and which values the host will store.
@MainActor
struct PluginSettingsTests {
    @Test
    func valuesAreKeptPerPluginAndAnEmptyRecordLeavesNothingBehind() {
        let preferences = SettingsKeyValueStore()
        let store = MacPluginSettingsStore(store: preferences)

        store.setValue(.integer(2048), forSetting: "heapMB", plugin: "dev.example.one")
        store.setValue(.string("debug"), forSetting: "logLevel", plugin: "dev.example.two")

        #expect(store.values(forPlugin: "dev.example.one") == ["heapMB": .integer(2048)])
        #expect(store.values(forPlugin: "dev.example.two") == ["logLevel": .string("debug")])
        #expect(MacPluginSettingsStore(store: preferences).values(forPlugin: "dev.example.one")
            == ["heapMB": .integer(2048)])

        store.setValue(nil, forSetting: "heapMB", plugin: "dev.example.one")
        #expect(store.values(forPlugin: "dev.example.one").isEmpty)
        #expect(preferences.keys == ["lithe.plugins.dev.example.two.settings"])
    }

    /// A damaged preference must never keep a language server from starting.
    @Test
    func anUnreadableRecordCountsAsEmptyAndTheNextChangeReplacesIt() {
        let preferences = SettingsKeyValueStore()
        preferences.set(Data("not json".utf8), forKey: "lithe.plugins.dev.example.one.settings")
        let store = MacPluginSettingsStore(store: preferences)

        #expect(store.values(forPlugin: "dev.example.one").isEmpty)

        store.setValue(.bool(true), forSetting: "telemetry", plugin: "dev.example.one")
        #expect(store.values(forPlugin: "dev.example.one") == ["telemetry": .bool(true)])
    }

    @Test
    func theManagerShowsEffectiveValuesAndStoresOnlyAcceptedOnes() throws {
        let settings = InMemoryPluginSettings()
        let manager = try makeManager(settings: settings)
        let pluginID = PluginID("dev.lithe.fixture.node-runtime")

        let initial = try #require(manager.snapshots.first { $0.id == pluginID })
        #expect(initial.settings.map(\.id) == ["heapMB", "logLevel", "telemetry"])
        #expect(initial.settings.allSatisfy { $0.isDefault })
        #expect(initial.settings.first?.value == .integer(2048))

        try manager.setSetting(.integer(4096), id: "heapMB", for: pluginID)
        try manager.setSetting(.string("debug"), id: "logLevel", for: pluginID)
        let changed = try #require(manager.snapshots.first { $0.id == pluginID })
        #expect(changed.settings.map(\.value) == [.integer(4096), .string("debug"), .bool(false)])
        #expect(changed.settings.map(\.isDefault) == [false, false, true])

        // A value outside the declaration is refused and leaves the stored one alone.
        #expect(throws: PluginManagerError.settingValueRejected(pluginID, "heapMB")) {
            try manager.setSetting(.integer(64), id: "heapMB", for: pluginID)
        }
        #expect(throws: PluginManagerError.settingValueRejected(pluginID, "logLevel")) {
            try manager.setSetting(.string("trace"), id: "logLevel", for: pluginID)
        }
        #expect(throws: PluginManagerError.unknownSetting(pluginID, "port")) {
            try manager.setSetting(.integer(1), id: "port", for: pluginID)
        }
        #expect(settings.values(forPlugin: pluginID.rawValue)["heapMB"] == .integer(4096))
    }

    /// Choosing the default again forgets the value, so a later change of the
    /// plugin's default still reaches this user.
    @Test
    func choosingTheDefaultOrResettingForgetsTheStoredValue() throws {
        let settings = InMemoryPluginSettings()
        let manager = try makeManager(settings: settings)
        let pluginID = PluginID("dev.lithe.fixture.node-runtime")

        try manager.setSetting(.integer(4096), id: "heapMB", for: pluginID)
        try manager.setSetting(.integer(2048), id: "heapMB", for: pluginID)
        #expect(settings.values(forPlugin: pluginID.rawValue)["heapMB"] == nil)

        try manager.setSetting(.bool(true), id: "telemetry", for: pluginID)
        try manager.setSetting(nil, id: "telemetry", for: pluginID)
        #expect(settings.values(forPlugin: pluginID.rawValue)["telemetry"] == nil)
    }

    @Test
    func theJavaPluginOffersMaximumMemoryAndLogLevelWithTheCurrentBehaviorAsDefault() throws {
        let descriptor = try DeclarativePluginTestSupport.officialDescriptor("JavaSupport")

        #expect(descriptor.settings.map(\.id) == ["heapMaxMB", "logLevel"])
        let heap = try #require(descriptor.settings.first { $0.id == "heapMaxMB" })
        // The language server starts with a 2 GB heap and full logging. A smaller
        // heap makes JDT LS import Maven modules in its constrained-memory mode,
        // which fails the whole Java service for modules that share coordinates,
        // so the plugin does not offer one.
        #expect(heap.defaultValue == .integer(2048))
        #expect(heap.kind == .integer(minimum: 2048, maximum: 16384, unit: "MB"))
        let level = try #require(descriptor.settings.first { $0.id == "logLevel" })
        #expect(level.defaultValue == .string("ALL"))
        #expect(level.accepts(.string("SEVERE")) && !level.accepts(.string("OFF")))
    }

    /// The Java plugin's choices end up on the JVM command line.
    @Test
    func theJavaPluginPassesItsSettingsToTheJvm() throws {
        let descriptor = try DeclarativePluginTestSupport.officialDescriptor("JavaSupport")
        let source = DeclarativeLanguageServerLaunchSource(
            pluginID: descriptor.id.rawValue,
            languageID: "java",
            manifest: descriptor.normalizedManifest,
            packageURL: URL(fileURLWithPath: "/plugins/java")
        )
        let settings = InMemoryPluginSettings([
            descriptor.id.rawValue: ["heapMaxMB": .integer(3072), "logLevel": .string("WARNING")]
        ])
        let request = DeclarativeLanguageServerLaunchRequest(
            pluginDirectory: source.packageURL,
            stateDirectory: URL(fileURLWithPath: "/state"),
            workspaceStateDirectory: URL(fileURLWithPath: "/state/workspace"),
            architecture: MacPluginLanguageServerLaunchResolver.hostArchitecture,
            settings: settings.values(forPlugin: descriptor.id.rawValue)
        )

        let plan = try DeclarativePluginTestSupport.operations.languageServerLaunchPlan(
            manifest: source.manifest,
            languageID: "java",
            request: request
        )

        #expect(plan.arguments.prefix(2) == ["-Xmx3072m", "-Dlog.level=WARNING"])
    }

    private func makeManager(settings: InMemoryPluginSettings) throws -> MacPluginManager {
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("shared/contracts/plugins/v1/fixtures/node-runtime.plugin.json"))
        )
        let installed = InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .marketplace
            ),
            packageURL: FileManager.default.temporaryDirectory
        )
        let configuration = MacModuleConfigurationStore(store: SettingsKeyValueStore())
        return MacPluginManager(
            packageStore: MacPluginPackageStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lithe-plugin-settings-\(UUID().uuidString)", isDirectory: true),
                validator: DeclarativePluginTestSupport.operations
            ),
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            settings: settings,
            launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: [installed], registeredPlugins: [], issues: [])
        )
    }
}

private final class SettingsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    var keys: Set<String> { Set(values.keys) }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
