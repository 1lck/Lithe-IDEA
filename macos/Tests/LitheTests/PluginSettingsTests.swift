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

    @Test
    func textSettingLengthUsesUnicodeScalars() {
        let setting = DeclarativePluginSetting(
            id: "label",
            title: "Label",
            summary: nil,
            kind: .text(pattern: ".*", maxLength: 2, placeholder: nil),
            defaultValue: .string("")
        )
        #expect(setting.accepts(.string("e\u{301}")))
        #expect(!setting.accepts(.string("e\u{301}x")))
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

    // MARK: Settings v2: layers, pages, and buttons

    @Test
    func projectValuesLiveInTheProjectAndAnEmptyDocumentLeavesNoFile() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let store = MacPluginSettingsStore(store: SettingsKeyValueStore())
        let file = project.appendingPathComponent(".lithe/plugin-settings.json")

        try store.setProjectValue(.string("prod"), forSetting: "mixEnv", plugin: "dev.example.one", projectRoot: project)
        #expect(store.projectValues(forPlugin: "dev.example.one", projectRoot: project) == ["mixEnv": .string("prod")])
        #expect(store.values(forPlugin: "dev.example.one").isEmpty)
        let document = try JSONDecoder().decode([String: [String: ToolingJSONValue]].self, from: Data(contentsOf: file))
        #expect(document == ["dev.example.one": ["mixEnv": .string("prod")]])

        try store.setProjectValue(nil, forSetting: "mixEnv", plugin: "dev.example.one", projectRoot: project)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The project file is shared through version control: a file this host
    /// cannot read must survive a change instead of being replaced or deleted.
    @Test
    func anUnreadableProjectFileIsRefusedAndKept() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let store = MacPluginSettingsStore(store: SettingsKeyValueStore())
        let file = project.appendingPathComponent(".lithe/plugin-settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data(#"{"version": 2, "dev.example.two": {"a": 1}}"#.utf8)
        try damaged.write(to: file)

        #expect(store.projectValues(forPlugin: "dev.example.two", projectRoot: project).isEmpty)
        #expect(throws: (any Error).self) {
            try store.setProjectValue(nil, forSetting: "mixEnv", plugin: "dev.example.one", projectRoot: project)
        }
        #expect(throws: (any Error).self) {
            try store.setProjectValue(.string("prod"), forSetting: "mixEnv", plugin: "dev.example.one", projectRoot: project)
        }
        #expect(try Data(contentsOf: file) == damaged)
    }

    /// A checked-out symbolic link, even a dangling one, must not redirect
    /// project settings outside the project.
    @Test
    func symbolicLinksAtTheProjectSettingsPathAreRefused() throws {
        let project = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = MacPluginSettingsStore(store: SettingsKeyValueStore())
        let directory = project.appendingPathComponent(".lithe")
        let dangling = outside.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: dangling)

        #expect(throws: (any Error).self) {
            try store.setProjectValue(.string("prod"), forSetting: "mixEnv", plugin: "dev.example.one", projectRoot: project)
        }
        #expect(!FileManager.default.fileExists(atPath: dangling.path))

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("settings.json")
        try Data(#"{"dev.example.one": {"mixEnv": "test"}}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("plugin-settings.json"),
            withDestinationURL: target
        )
        #expect(store.projectValues(forPlugin: "dev.example.one", projectRoot: project).isEmpty)
        #expect(throws: (any Error).self) {
            try store.setProjectValue(nil, forSetting: "mixEnv", plugin: "dev.example.one", projectRoot: project)
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// The page shows the value Rust Core launches with only if both sides
    /// accept the same values; these cases differed before.
    @Test
    func valueChecksMatchRustCoreForTextAndPaths() {
        let text = DeclarativePluginSetting(
            id: "name", title: "Name", summary: nil,
            kind: .text(pattern: ".+", maxLength: 3, placeholder: nil),
            defaultValue: .string("a")
        )
        // One grapheme, two Unicode scalars each: Core counts scalars.
        #expect(!text.accepts(.string("e\u{301}e\u{301}")))
        // A zero-width joiner is a format character, not a control one.
        #expect(text.accepts(.string("a\u{200D}b")))
        #expect(!text.accepts(.string("a\u{7}")))

        let path = DeclarativePluginSetting(
            id: "home", title: "Home", summary: nil,
            kind: .path(directory: true, placeholder: nil),
            defaultValue: .string("")
        )
        #expect(path.accepts(.string("/opt/tool")))
        #expect(path.accepts(.string("C:\\tools\\jdk")))
        #expect(path.accepts(.string("d:/tools")))
        #expect(!path.accepts(.string("tools/jdk")))
        #expect(!path.accepts(.string("1:/tools")))
    }

    @Test
    func projectSettingsRejectDanglingLitheSymlink() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let destination = project.appendingPathComponent("outside-missing", isDirectory: true)
        let directory = project.appendingPathComponent(".lithe", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: destination)
        let store = MacPluginSettingsStore(store: SettingsKeyValueStore())

        var rejected = false
        do {
            try store.setProjectValue(.string("prod"), forSetting: "mixEnv", plugin: "dev.example.one", projectRoot: project)
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugin-settings.json").path))
    }

    @Test
    func aProjectValueWinsOnlyForProjectScopedSettings() async throws {
        try await withV2Manager { manager in
            let project = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: project) }
            manager.settingsProjectRootURL = project
            let pluginID = PluginID("dev.lithe.fixture.settings-v2")

            try manager.setSetting(.string("test"), id: "mixEnv", for: pluginID, layer: .global)
            try manager.setSetting(.string("prod"), id: "mixEnv", for: pluginID, layer: .project)
            let mixEnv = try #require(setting("mixEnv", of: pluginID, in: manager))
            #expect(mixEnv.value == .string("prod"))
            #expect(mixEnv.source == .project)
            #expect(mixEnv.globalValue == .string("test"))

            // `checks` is global; a project cannot override it.
            #expect(throws: PluginManagerError.projectSettingUnavailable(pluginID, "checks")) {
                try manager.setSetting(.array([.string("credo")]), id: "checks", for: pluginID, layer: .project)
            }
            // A text value must match the declared pattern in whole.
            #expect(throws: PluginManagerError.settingValueRejected(pluginID, "mixEnv")) {
                try manager.setSetting(.string("Prod-1"), id: "mixEnv", for: pluginID, layer: .global)
            }

            manager.settingsProjectRootURL = nil
            #expect(try #require(setting("mixEnv", of: pluginID, in: manager)).source == .global)
        }
    }

    @Test
    func pluginsRegisterLanguageAndBuildSystemPagesWithTheirOwnSectionsAndButtons() async throws {
        try await withV2Manager { manager in
            try await manager.setEnabled(true, for: PluginID("dev.lithe.fixture.settings-v2"))
            let pages = PluginSettingsRegistry.pages(from: manager.snapshots)

            #expect(pages.map(\.id) == ["buildSystem:mix", "language:elixir"])
            let build = try #require(pages.first)
            #expect(build.group == .build)
            #expect(build.contributions.flatMap(\.settings).map(\.id) == ["checks"])
            #expect(build.contributions.flatMap(\.actions).isEmpty)

            let language = try #require(pages.last)
            #expect(language.group == .languages)
            #expect(language.title == "Elixir")
            let contribution = try #require(language.contributions.first)
            #expect(contribution.providesLanguageServer)
            #expect(contribution.settings.map(\.id) == ["dialyzer", "mixEnv"])
            #expect(contribution.settings.map(\.declaration.section) == [nil, "Server"])
            #expect(contribution.actions.map(\.functionID) == ["dialyzer.rebuild"])
            #expect(contribution.actions.first?.requiresConfirmation == true)
            #expect(language.searchTerms.contains("Rebuild PLT"))
        }
    }

    @Test
    func aDisabledPluginRegistersNoPages() async throws {
        try await withV2Manager { manager in
            try await manager.setEnabled(false, for: PluginID("dev.lithe.fixture.settings-v2"))
            #expect(PluginSettingsRegistry.pages(from: manager.snapshots).isEmpty)
        }
    }

    @Test
    func immediateSettingsExpandIntoTheServersWorkspaceConfiguration() async throws {
        try await withV2Manager { manager in
            let pluginID = PluginID("dev.lithe.fixture.settings-v2")
            #expect(manager.workspaceConfiguration(forPlugin: pluginID, languageID: "elixir")
                == .object(["elixirLS": .object(["dialyzerEnabled": .bool(true)])]))

            try manager.setSetting(.bool(false), id: "dialyzer", for: pluginID, layer: .global)
            #expect(manager.workspaceConfiguration(forPlugin: pluginID, languageID: "elixir")
                == .object(["elixirLS": .object(["dialyzerEnabled": .bool(false)])]))
        }
    }

    private func setting(_ id: String, of pluginID: PluginID, in manager: MacPluginManager) -> PluginSettingState? {
        manager.snapshots.first { $0.id == pluginID }?.settings.first { $0.id == id }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The shared settings v2 fixture installed from a package directory
    /// that holds its `plugin.json`, with Rust Core expanding configuration.
    private func withV2Manager(_ body: (MacPluginManager) async throws -> Void) async throws {
        let package = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: package) }
        let manifest = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/settings-v2.plugin.json"))
        try manifest.write(to: package.appendingPathComponent("plugin.json"))
        try await body(makeManager(
            settings: MacPluginSettingsStore(store: SettingsKeyValueStore()),
            fixture: "settings-v2.plugin.json",
            packageURL: package
        ))
    }

    private func makeManager(
        settings: any PluginSettingsStoring,
        fixture: String = "node-runtime.plugin.json",
        packageURL: URL = FileManager.default.temporaryDirectory
    ) throws -> MacPluginManager {
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("shared/contracts/plugins/v1/fixtures/\(fixture)"))
        )
        let installed = InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .marketplace
            ),
            packageURL: packageURL
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
            startup: MacPluginStartupResult(installedPlugins: [installed], registeredPlugins: [], issues: []),
            expandWorkspaceConfiguration: { manifest, languageID, global, project in
                try DeclarativePluginTestSupport.operations.workspaceConfiguration(
                    manifest: manifest, languageID: languageID, settings: global, projectSettings: project
                )
            }
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
