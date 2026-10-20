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
        // Go and PHP moved to Lithe Store: installed copies keep their pinned
        // publisher signature, but the host no longer suggests them.
        #expect(OfficialPluginCatalog.publishedEntries.map(\.id) == [OfficialPluginCatalog.javaPluginID])
        #expect(OfficialPluginCatalog.entry(for: OfficialPluginCatalog.goPluginID)?.communityReplacementID
            == PluginID("io.github.lithe-idea.go-support"))
        #expect(OfficialPluginCatalog.entry(for: OfficialPluginCatalog.phpPluginID)?.communityReplacementID
            == PluginID("io.github.lithe-idea.php-support"))
        #expect([OfficialPluginCatalog.goPluginID, OfficialPluginCatalog.phpPluginID].allSatisfy {
            OfficialPluginCatalog.entry(for: $0)?.signatureRequirement == .publisherPackage
        })
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
            settings: InMemoryPluginSettings(),
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
            settings: InMemoryPluginSettings(),
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
            settings: InMemoryPluginSettings(),
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
        var invalidated: [PluginID] = []
        var webPagesEnabled: [PluginID] = []
        let manager = MacPluginManager(
            packageStore: makeStore(root: root),
            moduleRuntime: runtime,
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                registeredPlugins: [installed],
                issues: []
            ),
            invalidateWebPages: { invalidated.append($0) },
            enableWebPages: { webPagesEnabled.append($0) }
        )

        try await manager.setEnabled(false, for: installed.manifest.id)

        #expect(invalidated == [installed.manifest.id])
        #expect(recorder.shutdownCount == 1)
        #expect(try runtime.snapshot(for: pluginModuleID).state == .disabled)
        let disabled = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(!disabled.isEnabled)
        #expect(!disabled.requiresRestart)

        try await manager.setEnabled(true, for: installed.manifest.id)
        let enabled = try #require(manager.snapshots.first { $0.id == installed.manifest.id })
        #expect(enabled.isEnabled)
        #expect(!enabled.requiresRestart)
        #expect(invalidated == [installed.manifest.id])
        #expect(webPagesEnabled == [installed.manifest.id])
    }

    @Test
    func packageMutationUsesItsOwnLifecycleNotification() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed"),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true)
        )
        let pluginID = PluginID("dev.example.lifecycle")
        func package(_ patch: Int) throws -> URL {
            try DeclarativePluginTestSupport.writePackage(
                at: root.appendingPathComponent("source-\(patch)"),
                manifest: DeclarativePluginTestSupport.manifestObject(
                    id: pluginID.rawValue, version: PluginVersion(major: 0, minor: 3, patch: patch),
                    // Development installs omit a required publisher signature;
                    // `none` is reserved for confirmed community packages.
                    signatureRequirement: .publisherPackage
                )
            )
        }
        let first = try store.installPackage(from: package(0), origin: .localDevelopment)
        let preferences = PluginManagerKeyValueStore()
        let configuration = MacModuleConfigurationStore(store: preferences)
        var disabled: [PluginID] = []
        var mutations: [PluginID] = []
        let manager = MacPluginManager(
            packageStore: store,
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: [first], registeredPlugins: [], issues: []),
            allowsLocalDevelopmentPackages: true,
            invalidateWebPages: { disabled.append($0) },
            beforePackageReplacement: { mutations.append($0) }
        )
        try manager.installPackage(at: package(1))
        #expect(manager.snapshots.first { $0.id == pluginID }?.origin == .localDevelopment)
        #expect(mutations == [pluginID])
        #expect(disabled.isEmpty)
        try manager.rollback(pluginID)
        #expect(mutations == [pluginID, pluginID])
        #expect(disabled.isEmpty)
        try await manager.uninstall(pluginID)
        #expect(mutations == [pluginID, pluginID, pluginID])
        #expect(disabled.isEmpty)
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
            settings: InMemoryPluginSettings(),
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

    /// Migration from a retired official plugin to its community replacement:
    /// both declare the same language module. Uninstalling the enabled old
    /// package stops the module, but that must not count as the user turning
    /// it off, or the replacement would install disabled.
    @Test
    func uninstallingAnEnabledPluginLetsItsReplacementStartEnabled() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MacModuleConfigurationStore(store: PluginManagerKeyValueStore())
        configuration.setEnabledState(true, for: pluginModuleID)

        try await uninstallRegisteredPackage(root: root, configuration: configuration)
        #expect(configuration.enabledState(for: pluginModuleID) == nil)

        let replacement = try installReplacementAfterRestart(root: root, configuration: configuration)
        #expect(configuration.enabledState(for: pluginModuleID) == true)
        #expect(replacement.isEnabled)
        #expect(replacement.requiresRestart)
    }

    @Test
    func uninstallKeepsAnExplicitlyDisabledModuleOff() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MacModuleConfigurationStore(store: PluginManagerKeyValueStore())
        configuration.setEnabledState(true, for: pluginModuleID)

        try await uninstallRegisteredPackage(root: root, configuration: configuration, disableFirst: true)
        #expect(configuration.enabledState(for: pluginModuleID) == false)

        let replacement = try installReplacementAfterRestart(root: root, configuration: configuration)
        #expect(configuration.enabledState(for: pluginModuleID) == false)
        #expect(!replacement.isEnabled)
    }

    private func lifecyclePackage(root: URL, id: String) throws -> URL {
        try DeclarativePluginTestSupport.writePackage(
            at: root.appendingPathComponent("source-\(id)"),
            manifest: DeclarativePluginTestSupport.manifestObject(
                id: id,
                version: PluginVersion(major: 0, minor: 3, patch: 0),
                signatureRequirement: .publisherPackage
            )
        )
    }

    private func lifecycleStore(root: URL) -> MacPluginPackageStore {
        MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed"),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true)
        )
    }

    /// The old package is installed, registered, and running, then the user
    /// (optionally after disabling it) uninstalls it.
    private func uninstallRegisteredPackage(
        root: URL,
        configuration: MacModuleConfigurationStore,
        disableFirst: Bool = false
    ) async throws {
        let store = lifecycleStore(root: root)
        let old = try store.installPackage(
            from: lifecyclePackage(root: root, id: "dev.example.retired"),
            origin: .localDevelopment
        )
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        let moduleManifest = try #require(old.manifest.modules.first?.manifest)
        #expect(moduleManifest.id == pluginModuleID)
        let workspace = try #require(BuiltInModuleCatalog.manifest(for: .workspace))
        try runtime.register(ModuleFactory(manifest: workspace) { PluginManagerWorkspaceModule(manifest: workspace) })
        let recorder = PluginManagerModuleRecorder()
        try runtime.register(ModuleFactory(manifest: moduleManifest) {
            PluginManagerTestModule(manifest: moduleManifest, recorder: recorder)
        })
        _ = try await runtime.activate(pluginModuleID)
        let manager = MacPluginManager(
            packageStore: store,
            moduleRuntime: runtime,
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: [old], registeredPlugins: [old], issues: []),
            allowsLocalDevelopmentPackages: true
        )
        if disableFirst { try await manager.setEnabled(false, for: old.manifest.id) }

        try await manager.uninstall(old.manifest.id)

        #expect(recorder.shutdownCount == 1)
        #expect(try runtime.snapshot(for: pluginModuleID).state == .disabled)
        let pending = try #require(manager.snapshots.first { $0.id == old.manifest.id })
        #expect(pending.installationStatus == .uninstallPending)
        #expect(pending.hasChangesPendingRestart)
    }

    /// Restart (the old package is removed at launch), then install the
    /// replacement that declares the same language module.
    private func installReplacementAfterRestart(
        root: URL,
        configuration: MacModuleConfigurationStore
    ) throws -> PluginManagementSnapshot {
        let store = lifecycleStore(root: root)
        try store.prepareForLaunch()
        let scan = try store.scanInstalledPlugins()
        #expect(scan.packages.isEmpty)
        let manager = MacPluginManager(
            packageStore: store,
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: scan.packages, registeredPlugins: [], issues: []),
            allowsLocalDevelopmentPackages: true
        )
        let replacementID = PluginID("dev.example.replacement")
        try manager.installPackage(at: lifecyclePackage(root: root, id: replacementID.rawValue))
        let snapshot = try #require(manager.snapshots.first { $0.id == replacementID })
        #expect(snapshot.hasChangesPendingRestart)
        return snapshot
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
