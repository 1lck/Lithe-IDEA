import Foundation
@testable import Lithe
import LitheModuleAPI
import Testing

@MainActor
struct NativePluginLoaderTests {
    @Test
    func disabledPluginDoesNotLoadItsBundle() throws {
        let codeLoader = TestPrincipalClassLoader()
        let loader = MacNativePluginLoader(codeLoader: codeLoader)
        let installed = installedTestPlugin()
        let policy = MacPluginLoadPolicy(
            configurationStore: TestPluginConfigurationStore(enabled: false),
            recoveryStore: nil,
            launchMode: .normal
        )

        let factories = try loader.loadFactories(from: [installed], policy: policy)

        #expect(factories.isEmpty)
        #expect(codeLoader.loadCount == 0)
    }

    @Test
    func quarantinedAndSafeModePluginsDoNotLoadTheirBundles() throws {
        let installed = installedTestPlugin()
        let recovery = TestPluginRecoveryStore(quarantined: [testModuleManifest.id])
        let quarantinedLoader = TestPrincipalClassLoader()
        let safeModeLoader = TestPrincipalClassLoader()

        let quarantined = try MacNativePluginLoader(codeLoader: quarantinedLoader).loadFactories(
            from: [installed],
            policy: MacPluginLoadPolicy(
                configurationStore: TestPluginConfigurationStore(enabled: true),
                recoveryStore: recovery,
                launchMode: .normal
            )
        )
        let safeMode = try MacNativePluginLoader(codeLoader: safeModeLoader).loadFactories(
            from: [installed],
            policy: MacPluginLoadPolicy(
                configurationStore: TestPluginConfigurationStore(enabled: true),
                recoveryStore: nil,
                launchMode: .safeMode
            )
        )

        #expect(quarantined.isEmpty)
        #expect(safeMode.isEmpty)
        #expect(quarantinedLoader.loadCount == 0)
        #expect(safeModeLoader.loadCount == 0)
    }

    @Test
    func enabledPluginLoadsAndMustMatchItsStaticFactoryCatalog() throws {
        let codeLoader = TestPrincipalClassLoader()
        let loader = MacNativePluginLoader(codeLoader: codeLoader)
        let installed = installedTestPlugin()
        let policy = MacPluginLoadPolicy(
            configurationStore: TestPluginConfigurationStore(enabled: true),
            recoveryStore: nil,
            launchMode: .normal
        )

        let factories = try loader.loadFactories(from: [installed], policy: policy)

        #expect(factories[installed.manifest.id]?.map(\.manifest.id) == [testModuleManifest.id])
        #expect(codeLoader.loadCount == 1)
    }

    private func installedTestPlugin() -> InstalledPluginPackage {
        let version = PluginVersion(major: 0, minor: 3, patch: 0)
        let manifest = PluginManifest(
            id: PluginID("dev.example.plugin"),
            displayName: "Example Plugin",
            version: version,
            hostCompatibility: PluginHostCompatibility(
                minimum: version,
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: PluginVendor(
                id: "dev.example",
                displayName: "Example",
                signatureRequirement: .sameTeamAsHost
            ),
            entrypoint: PluginEntrypoint(
                kind: .nativeBundle,
                bundleIdentifier: "dev.example.plugin",
                principalClass: "TestNativePluginEntrypoint",
                bundlePath: "Example.bundle"
            ),
            modules: [PluginModuleDeclaration(manifest: testModuleManifest)]
        )
        return InstalledPluginPackage(
            manifest: manifest,
            installation: PluginInstallationRecord(
                pluginID: manifest.id,
                activeVersion: version,
                origin: .marketplace
            ),
            packageURL: URL(fileURLWithPath: "/tmp/lithe-test-plugin", isDirectory: true)
        )
    }
}

private let testModuleManifest = ModuleManifest(
    id: ModuleID("dev.example.feature"),
    displayName: "Example Feature",
    scope: .application,
    providedCapabilities: [ModuleCapabilityID("dev.example.feature.capability")]
)

private final class TestPrincipalClassLoader: PluginPrincipalClassLoading {
    private(set) var loadCount = 0

    func principalClass(at bundleURL: URL) throws -> AnyClass {
        loadCount += 1
        return TestNativePluginEntrypoint.self
    }
}

@MainActor
private final class TestNativePluginEntrypoint: LithePluginEntrypoint {
    required init() {}

    func moduleFactories(context: PluginHostContext) throws -> [ModuleFactory] {
        [ModuleFactory(manifest: testModuleManifest) {
            TestNativeModule()
        }]
    }
}

@MainActor
private final class TestNativeModule: LitheModule {
    let manifest = testModuleManifest
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        [ModuleCapabilityID("dev.example.feature.capability"): NSObject()]
    }
}

private final class TestPluginConfigurationStore: ModuleConfigurationStore, @unchecked Sendable {
    private let enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    func enabledState(for moduleID: ModuleID) -> Bool? { enabled }
    func setEnabledState(_ enabled: Bool, for moduleID: ModuleID) {}
}

private final class TestPluginRecoveryStore: ModuleRecoveryStore, @unchecked Sendable {
    private let quarantined: Set<ModuleID>
    init(quarantined: Set<ModuleID>) { self.quarantined = quarantined }
    func pendingActivation() -> ModuleID? { nil }
    func setPendingActivation(_ moduleID: ModuleID?) {}
    func isQuarantined(_ moduleID: ModuleID) -> Bool { quarantined.contains(moduleID) }
    func setQuarantined(_ quarantined: Bool, for moduleID: ModuleID) {}
}
