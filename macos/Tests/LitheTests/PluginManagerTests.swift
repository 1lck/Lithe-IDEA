import Foundation
@testable import Lithe
import LitheApplicationKernel
import LitheModuleAPI
import Testing

@MainActor
struct PluginManagerTests {
    @Test
    func bundledLanguageCatalogOnlyCreatesPluginsForImplementedProcessFeatures() throws {
        let expectedIDs: Set<String> = [
            "python", "node", "rust", "clangd", "csharp", "fsharp", "swift", "kotlin", "scala", "groovy",
            "ruby", "dart", "lua", "shell", "powershell", "html", "css", "vue", "svelte", "astro",
            "json", "yaml", "xml", "markdown", "sql", "terraform", "dockerfile", "cmake", "make", "toml",
            "graphql", "protobuf", "prisma", "elixir", "erlang", "haskell", "ocaml", "clojure", "julia",
            "r", "perl", "zig", "solidity"
        ]
        #expect(Set(BundledLanguagePluginCatalog.specifications.map(\.id)) == expectedIDs)
        #expect(Set(BundledLanguagePluginCatalog.languageSupports.map(\.id)) == expectedIDs)

        let expectedPluginIDs = Set(
            BundledLanguagePluginCatalog.specifications
                .filter { $0.supportsLanguageServer || $0.supportsExecution }
                .map(\.id)
        )
        #expect(Set(BundledLanguagePluginCatalog.manifests.compactMap {
            $0.languageSupports?.first?.id
        }) == expectedPluginIDs)
        #expect(BundledLanguagePluginCatalog.manifests.flatMap(\.modules).allSatisfy {
            $0.manifest.defaultState == .disabled
        })

        let markdown = try #require(BundledLanguagePluginCatalog.languageSupports.first {
            $0.id == "markdown"
        })
        let yaml = try #require(BundledLanguagePluginCatalog.languageSupports.first {
            $0.id == "yaml"
        })
        #expect(markdown.languageServerModuleID == nil)
        #expect(yaml.languageServerModuleID == .languageServerExtension("yaml"))
        // Java Support also proves that a plugin may own the Java language
        // alongside every built-in and bundled catalog without a collision.
        let officialLanguagePlugins = try ["GoSupport", "JavaSupport", "PhpSupport"].map {
            try DeclarativePluginTestSupport.officialDescriptor($0).pluginManifest
        }
        #expect(Set(officialLanguagePlugins.map(\.id)) == Set(OfficialPluginCatalog.entries.map(\.id)))
        #expect(officialLanguagePlugins.flatMap(\.modules).allSatisfy {
            $0.manifest.defaultState == .disabled
        })
        _ = try ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests
                + BundledLanguagePluginCatalog.manifests
                + officialLanguagePlugins,
            hostVersion: BuiltInPluginCatalog.hostVersion
        )
    }

    @Test
    func internalLifecycleModulesAreNotShownAsInstalledPlugins() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        let manager = MacPluginManager(
            packageStore: makeStore(root: root),
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                registeredPlugins: [],
                issues: []
            )
        )

        #expect(manager.snapshots.isEmpty)
    }

    @Test
    func internalDatabaseModuleIsNotShownAsAPlugin() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let manager = MacPluginManager(
            packageStore: makeStore(root: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                registeredPlugins: [],
                issues: []
            ),
            managedBuiltInPlugins: []
        )

        #expect(manager.snapshots.isEmpty)
        #expect(try #require(BuiltInModuleCatalog.manifests.first { $0.id == .database }).defaultState == .enabled)
        #expect(configuration.enabledState(for: .database) == nil)
    }

    @Test
    func enablingAPluginInstalledAfterLaunchPersistsPreferenceAndRequiresRestart() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let installed = try installedPlugin()
        let manager = MacPluginManager(
            packageStore: makeStore(root: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                registeredPlugins: [],
                issues: []
            )
        )

        try await manager.setEnabled(true, for: installed.manifest.id)

        #expect(configuration.enabledState(for: pluginModuleID) == true)
        let snapshot = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(snapshot.isEnabled)
        #expect(snapshot.requiresRestart)
    }

    /// A declarative plugin registered at launch has no code mapped in the
    /// process, so enabling and disabling apply without a restart.
    @Test
    func registeredPluginIsDisabledAndReEnabledWithoutRestart() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        configuration.setEnabledState(true, for: pluginModuleID)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let recorder = PluginManagerModuleRecorder()
        let installed = try installedPlugin()
        let moduleManifest = try #require(installed.manifest.modules.first?.manifest)
        let workspace = try #require(BuiltInModuleCatalog.manifest(for: .workspace))
        try runtime.register(ModuleFactory(manifest: workspace) {
            PluginManagerWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: moduleManifest) {
            PluginManagerTestModule(manifest: moduleManifest, recorder: recorder)
        })
        _ = try await runtime.activate(pluginModuleID)
        let manager = MacPluginManager(
            packageStore: makeStore(root: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                registeredPlugins: [installed],
                issues: []
            )
        )

        try await manager.setEnabled(false, for: installed.manifest.id)

        #expect(recorder.shutdownCount == 1)
        #expect(try runtime.snapshot(for: pluginModuleID).state == .disabled)
        let disabled = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(!disabled.isEnabled)
        #expect(!disabled.requiresRestart)

        try await manager.setEnabled(true, for: installed.manifest.id)
        let enabled = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(enabled.isEnabled)
        #expect(!enabled.requiresRestart)
    }

    @Test
    func quarantinedUnloadedPluginCanBeReEnabledDirectly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        configuration.setEnabledState(true, for: pluginModuleID)
        configuration.setQuarantined(true, for: pluginModuleID)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let installed = try installedPlugin()
        let manager = MacPluginManager(
            packageStore: makeStore(root: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                registeredPlugins: [],
                issues: []
            )
        )

        let quarantined = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(!quarantined.isEnabled)
        #expect(quarantined.isQuarantined)

        try await manager.setEnabled(true, for: installed.manifest.id)

        #expect(!configuration.isQuarantined(pluginModuleID))
        let enabled = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(enabled.isEnabled)
        #expect(enabled.requiresRestart)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-manager-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(root: URL) -> MacPluginPackageStore {
        MacPluginPackageStore(rootURL: root, validator: DeclarativePluginTestSupport.operations)
    }

    private func installedPlugin() throws -> InstalledPluginPackage {
        let descriptor = try DeclarativePluginTestSupport.descriptor(
            DeclarativePluginTestSupport.manifestObject(
                id: "dev.example.manager-plugin",
                version: PluginVersion(major: 0, minor: 3, patch: 0)
            )
        )
        return InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .marketplace
            ),
            packageURL: temporaryRoot()
        )
    }
}

private let pluginModuleID = ModuleID.languageServerExtension("fixture")

@MainActor
private final class PluginManagerTestModule: LitheModule {
    let manifest: ModuleManifest
    private let recorder: PluginManagerModuleRecorder

    init(manifest: ModuleManifest, recorder: PluginManagerModuleRecorder) {
        self.manifest = manifest
        self.recorder = recorder
    }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async { recorder.shutdownCount += 1 }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        Dictionary(uniqueKeysWithValues: manifest.providedCapabilities.map { ($0, NSObject()) })
    }
}

/// Satisfies the workspace dependency every language module declares.
@MainActor
private final class PluginManagerWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private let capability = NSObject()

    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [.workspaceFoundation: capability] }
}

@MainActor
private final class PluginManagerModuleRecorder {
    var shutdownCount = 0
}

private final class PluginManagerKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
