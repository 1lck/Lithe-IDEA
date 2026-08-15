import Foundation
@testable import Lithe
import LitheApplicationKernel
import LitheModuleAPI
import Testing

@MainActor
struct PluginManagerTests {
    @Test
    func bundledLanguagePluginsCoverEveryNonJavaNonGoProvider() throws {
        let expectedIDs: Set<String> = [
            "python", "node", "rust", "clangd", "csharp", "fsharp", "swift", "kotlin", "scala", "groovy",
            "ruby", "php", "dart", "lua", "shell", "powershell", "html", "css", "vue", "svelte", "astro",
            "json", "yaml", "xml", "markdown", "sql", "terraform", "dockerfile", "cmake", "make", "toml",
            "graphql", "protobuf", "prisma", "elixir", "erlang", "haskell", "ocaml", "clojure", "julia",
            "r", "perl", "zig", "solidity"
        ]
        #expect(Set(BundledLanguagePluginCatalog.specifications.map(\.id)) == expectedIDs)
        #expect(BundledLanguagePluginCatalog.manifests.count == expectedIDs.count)
        #expect(BundledLanguagePluginCatalog.manifests.flatMap(\.modules).allSatisfy {
            $0.manifest.defaultState == .disabled
        })
        #expect(OfficialPluginCatalog.manifests.flatMap(\.modules).allSatisfy {
            $0.manifest.defaultState == .disabled
        })
        _ = try ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests
                + BundledLanguagePluginCatalog.manifests
                + OfficialPluginCatalog.manifests,
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
            packageStore: MacPluginPackageStore(rootURL: root),
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                issues: []
            )
        )

        #expect(manager.snapshots.isEmpty)
    }

    @Test
    func selectedBuiltInModuleIsShownAsBundledPluginAndCanBeEnabled() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let manifest = try #require(BuiltInPluginCatalog.manifest(forModule: .database))
        let manager = MacPluginManager(
            packageStore: MacPluginPackageStore(rootURL: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                issues: []
            ),
            managedBuiltInPlugins: [manifest]
        )

        let initial = try #require(manager.snapshots.first)
        #expect(initial.origin == .bundled)
        #expect(!initial.isEnabled)

        try await manager.setEnabled(true, for: manifest.id)

        #expect(configuration.enabledState(for: .database) == true)
        #expect(try #require(manager.snapshots.first).isEnabled)
    }

    @Test
    func enablingUnloadedNativePluginPersistsPreferenceAndRequiresRestart() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let installed = installedPlugin(defaultState: .disabled)
        let manager = MacPluginManager(
            packageStore: MacPluginPackageStore(rootURL: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                issues: []
            )
        )

        try await manager.setEnabled(true, for: installed.manifest.id)

        #expect(configuration.enabledState(for: pluginManagerModuleManifest.id) == true)
        let snapshot = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(snapshot.isEnabled)
        #expect(snapshot.requiresRestart)
    }

    @Test
    func disablingLoadedNativePluginStopsItsModuleAndRequiresRestart() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        configuration.setEnabledState(true, for: pluginManagerModuleManifest.id)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let recorder = PluginManagerModuleRecorder()
        try runtime.register(ModuleFactory(manifest: pluginManagerModuleManifest) {
            PluginManagerTestModule(recorder: recorder)
        })
        _ = try await runtime.activate(pluginManagerModuleManifest.id)
        let installed = installedPlugin(defaultState: .enabled)
        let manager = MacPluginManager(
            packageStore: MacPluginPackageStore(rootURL: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                activeNativeManifests: [installed.manifest],
                factoriesByPlugin: [:],
                issues: []
            )
        )

        try await manager.setEnabled(false, for: installed.manifest.id)

        #expect(recorder.shutdownCount == 1)
        #expect(try runtime.snapshot(for: pluginManagerModuleManifest.id).state == .disabled)
        let snapshot = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(!snapshot.isEnabled)
        #expect(snapshot.requiresRestart)
    }

    @Test
    func quarantinedUnloadedPluginCanBeReEnabledDirectly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        configuration.setEnabledState(true, for: pluginManagerModuleManifest.id)
        configuration.setQuarantined(true, for: pluginManagerModuleManifest.id)
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let installed = installedPlugin(defaultState: .enabled)
        let manager = MacPluginManager(
            packageStore: MacPluginPackageStore(rootURL: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                issues: []
            )
        )

        let quarantined = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(!quarantined.isEnabled)
        #expect(quarantined.isQuarantined)

        try await manager.setEnabled(true, for: installed.manifest.id)

        #expect(!configuration.isQuarantined(pluginManagerModuleManifest.id))
        let enabled = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(enabled.isEnabled)
        #expect(enabled.requiresRestart)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-manager-\(UUID().uuidString)", isDirectory: true)
    }

    private func installedPlugin(defaultState: ModuleDefaultState) -> InstalledPluginPackage {
        let manifest = PluginManifest(
            id: PluginID("dev.example.manager-plugin"),
            displayName: "Manager Plugin",
            version: BuiltInPluginCatalog.hostVersion,
            hostCompatibility: PluginHostCompatibility(
                minimum: BuiltInPluginCatalog.hostVersion,
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: PluginVendor(
                id: "dev.example",
                displayName: "Example",
                signatureRequirement: .sameTeamAsHost
            ),
            entrypoint: PluginEntrypoint(
                kind: .nativeBundle,
                bundleIdentifier: "dev.example.manager-plugin",
                principalClass: "ExamplePlugin",
                bundlePath: "Example.bundle"
            ),
            modules: [PluginModuleDeclaration(manifest: ModuleManifest(
                id: pluginManagerModuleManifest.id,
                displayName: pluginManagerModuleManifest.displayName,
                scope: pluginManagerModuleManifest.scope,
                defaultState: defaultState,
                activationPolicy: pluginManagerModuleManifest.activationPolicy,
                sleepPolicy: pluginManagerModuleManifest.sleepPolicy,
                dependencies: pluginManagerModuleManifest.dependencies,
                providedCapabilities: pluginManagerModuleManifest.providedCapabilities
            ))]
        )
        return InstalledPluginPackage(
            manifest: manifest,
            installation: PluginInstallationRecord(
                pluginID: manifest.id,
                activeVersion: manifest.version,
                origin: .marketplace
            ),
            packageURL: temporaryRoot()
        )
    }
}

private let pluginManagerModuleManifest = ModuleManifest(
    id: ModuleID("dev.example.manager-module"),
    displayName: "Manager Module",
    scope: .application,
    defaultState: .enabled,
    activationPolicy: .onDemand
)

@MainActor
private final class PluginManagerTestModule: LitheModule {
    let manifest = pluginManagerModuleManifest
    private let recorder: PluginManagerModuleRecorder

    init(recorder: PluginManagerModuleRecorder) { self.recorder = recorder }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async { recorder.shutdownCount += 1 }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
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
