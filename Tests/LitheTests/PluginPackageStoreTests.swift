import Foundation
@testable import Lithe
import LitheModuleAPI
import Testing

struct PluginPackageStoreTests {
    @Test
    func bundledOfficialPluginIsVisibleWithoutAUserInstallation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackage(
            root: root,
            name: "dev.example.plugin",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: source,
            to: bundledRoot.appendingPathComponent("dev.example.plugin", isDirectory: true)
        )
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            bundledRootURL: bundledRoot,
            verifier: TestPluginSignatureVerifier()
        )

        let plugin = try #require(try store.installedPlugins().first)

        #expect(plugin.installation.origin == .bundled)
        #expect(plugin.manifest.version == PluginVersion(major: 0, minor: 3, patch: 0))
    }

    @Test
    func validUserUpdateOverridesBundledVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledSource = try makePackage(
            root: root,
            name: "dev.example.plugin",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: bundledSource,
            to: bundledRoot.appendingPathComponent("dev.example.plugin", isDirectory: true)
        )
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            bundledRootURL: bundledRoot,
            verifier: TestPluginSignatureVerifier()
        )
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "update",
            version: PluginVersion(major: 0, minor: 3, patch: 1)
        ))

        let plugin = try #require(try store.installedPlugins().first)

        #expect(plugin.installation.origin == .marketplace)
        #expect(plugin.manifest.version == PluginVersion(major: 0, minor: 3, patch: 1))
    }

    @Test
    func installUpdateRollbackAndUninstallUseStaticManifests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = TestPluginSignatureVerifier()
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            verifier: verifier
        )
        let versionOne = PluginVersion(major: 0, minor: 3, patch: 0)
        let versionTwo = PluginVersion(major: 0, minor: 3, patch: 1)
        let firstSource = try makePackage(root: root, name: "first", version: versionOne)
        let secondSource = try makePackage(root: root, name: "second", version: versionTwo)

        let first = try store.installPackage(from: firstSource)
        #expect(first.installation.activeVersion == versionOne)
        #expect(first.installation.previousVersion == nil)

        let second = try store.installPackage(from: secondSource)
        #expect(second.installation.activeVersion == versionTwo)
        #expect(second.installation.previousVersion == versionOne)

        let scanned = try store.installedPlugins()
        #expect(scanned.map(\.manifest.version) == [versionTwo])
        #expect(verifier.verifiedVersions == [versionOne, versionTwo, versionTwo])

        let restored = try store.rollback(second.manifest.id)
        #expect(restored.installation.activeVersion == versionOne)
        #expect(restored.installation.previousVersion == versionTwo)

        try store.uninstall(second.manifest.id)
        #expect(try store.installedPlugins().isEmpty)
    }

    @Test
    func damagedPackageDoesNotHideValidInstalledPlugins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let store = MacPluginPackageStore(
            rootURL: installedRoot,
            verifier: TestPluginSignatureVerifier()
        )
        let source = try makePackage(
            root: root,
            name: "valid",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        _ = try store.installPackage(from: source)
        try FileManager.default.createDirectory(
            at: installedRoot.appendingPathComponent("dev.example.broken", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = try store.scanInstalledPlugins()

        #expect(result.packages.map(\.manifest.id) == [PluginID("dev.example.plugin")])
        #expect(result.issues.count == 1)
    }

    @Test
    func damagedPackageCanBeRemovedWithoutReadingItsManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let store = MacPluginPackageStore(
            rootURL: installedRoot,
            verifier: TestPluginSignatureVerifier()
        )
        let installed = try store.installPackage(from: makePackage(
            root: root,
            name: "damaged",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        ))
        try FileManager.default.removeItem(
            at: installed.packageURL.appendingPathComponent("plugin.json")
        )
        #expect(try store.scanInstalledPlugins().issues.count == 1)

        try store.stageInvalidPackageUninstall(installed.manifest.id)
        try store.prepareForLaunch()

        #expect(try store.scanInstalledPlugins().packages.isEmpty)
        #expect(try store.scanInstalledPlugins().issues.isEmpty)
    }

    @Test
    func rejectedUpdateLeavesCurrentVersionActive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let versionOne = PluginVersion(major: 0, minor: 3, patch: 0)
        let versionTwo = PluginVersion(major: 0, minor: 3, patch: 1)
        let verifier = TestPluginSignatureVerifier(rejectedVersions: [versionTwo])
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            verifier: verifier
        )
        let firstSource = try makePackage(root: root, name: "first", version: versionOne)
        let secondSource = try makePackage(root: root, name: "second", version: versionTwo)

        _ = try store.installPackage(from: firstSource)
        #expect(throws: TestPluginSignatureError.rejected) {
            _ = try store.installPackage(from: secondSource)
        }

        let installed = try #require(try store.installedPlugins().first)
        #expect(installed.manifest.version == versionOne)
        #expect(installed.installation.previousVersion == nil)
    }

    @Test
    func requiredPluginCannotBeUninstalled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = TestPluginSignatureVerifier()
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            verifier: verifier
        )
        let source = try makePackage(
            root: root,
            name: "required",
            version: PluginVersion(major: 0, minor: 3, patch: 0),
            required: true
        )
        let installed = try store.installPackage(from: source)

        #expect(throws: PluginPackageStoreError.requiredPluginCannotBeUninstalled(
            installed.manifest.id
        )) {
            try store.uninstall(installed.manifest.id)
        }
    }

    @Test
    func deferredUpdateAndUninstallCompleteAtNextLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            verifier: TestPluginSignatureVerifier()
        )
        let versionOne = PluginVersion(major: 0, minor: 3, patch: 0)
        let versionTwo = PluginVersion(major: 0, minor: 3, patch: 1)
        _ = try store.installPackage(from: makePackage(root: root, name: "one", version: versionOne))
        let updated = try store.installPackage(
            from: makePackage(root: root, name: "two", version: versionTwo),
            deferActivationUntilRestart: true
        )
        #expect(updated.installation.status == .updateStaged)

        try store.prepareForLaunch()
        let active = try #require(try store.installedPlugins().first)
        #expect(active.installation.status == .installed)
        #expect(active.manifest.version == versionTwo)

        try store.stageUninstall(active.manifest.id)
        let pending = try #require(try store.installedPlugins().first)
        #expect(pending.installation.status == .uninstallPending)
        try store.prepareForLaunch()
        #expect(try store.installedPlugins().isEmpty)
    }

    @MainActor
    @Test
    func interruptedPluginCodeLoadIsQuarantinedBeforeRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            verifier: TestPluginSignatureVerifier()
        )
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "recover",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        ))
        let moduleID = ModuleID("dev.example.feature")
        let recovery = PluginStartupRecoveryStore(pending: [moduleID])
        let codeLoader = CountingPluginPrincipalClassLoader()

        let result = MacPluginStartupLoader(
            packageStore: store,
            nativeLoader: MacNativePluginLoader(codeLoader: codeLoader)
        ).load(policy: MacPluginLoadPolicy(
            configurationStore: PluginStartupConfigurationStore(enabled: true),
            recoveryStore: recovery,
            launchMode: .normal
        ))

        #expect(result.activeNativeManifests.isEmpty)
        #expect(codeLoader.loadCount == 0)
        #expect(recovery.isQuarantined(moduleID))
        #expect(recovery.pendingPluginLoadModules().isEmpty)
    }

    @MainActor
    @Test
    func disabledLanguagePluginRetainsStaticOwnershipWithoutLoadingCode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            verifier: TestPluginSignatureVerifier()
        )
        let languageID = "fixture"
        let moduleID = ModuleID("dev.example.feature")
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "disabled-language",
            version: PluginVersion(major: 0, minor: 3, patch: 0),
            languageSupport: LanguageSupportDeclaration(
                id: languageID,
                displayName: "Fixture",
                fileExtensions: ["fixture"],
                languageServerModuleID: moduleID,
                executionModuleID: moduleID,
                testingModuleID: moduleID
            )
        ))
        let codeLoader = CountingPluginPrincipalClassLoader()

        let result = MacPluginStartupLoader(
            packageStore: store,
            nativeLoader: MacNativePluginLoader(codeLoader: codeLoader)
        ).load(policy: MacPluginLoadPolicy(
            configurationStore: PluginStartupConfigurationStore(enabled: false),
            recoveryStore: nil,
            launchMode: .normal
        ))

        #expect(result.activeNativeManifests.isEmpty)
        #expect(codeLoader.loadCount == 0)
        #expect(result.installedLanguageSupports.map(\.id) == [languageID])
    }

    @MainActor
    @Test
    func loadedPluginRemainsMarkedUntilCleanProcessShutdown() {
        let moduleID = ModuleID("dev.example.runtime-plugin")
        let recovery = PluginStartupRecoveryStore()
        let coordinator = MacPluginRuntimeRecoveryCoordinator()

        coordinator.recoverPreviousSession(using: recovery)
        coordinator.prepareToLoad([moduleID], using: recovery)
        coordinator.recordSuccessfulLoad([moduleID], using: recovery)

        #expect(recovery.pendingPluginLoadModules() == [moduleID])
        #expect(!recovery.isQuarantined(moduleID))

        coordinator.recordCleanShutdown(using: recovery)

        #expect(recovery.pendingPluginLoadModules().isEmpty)
    }

    @MainActor
    @Test
    func interruptedRuntimeSessionIsRecoveredOnlyOncePerProcess() {
        let previousModuleID = ModuleID("dev.example.previous-plugin")
        let currentModuleID = ModuleID("dev.example.current-plugin")
        let recovery = PluginStartupRecoveryStore(pending: [previousModuleID])
        let coordinator = MacPluginRuntimeRecoveryCoordinator()

        coordinator.recoverPreviousSession(using: recovery)
        #expect(recovery.isQuarantined(previousModuleID))
        #expect(recovery.pendingPluginLoadModules().isEmpty)

        coordinator.prepareToLoad([currentModuleID], using: recovery)
        coordinator.recordSuccessfulLoad([currentModuleID], using: recovery)
        coordinator.recoverPreviousSession(using: recovery)

        #expect(recovery.pendingPluginLoadModules() == [currentModuleID])
        #expect(!recovery.isQuarantined(currentModuleID))
    }

    private func makePackage(
        root: URL,
        name: String,
        version: PluginVersion,
        required: Bool = false,
        languageSupport: LanguageSupportDeclaration? = nil
    ) throws -> URL {
        let packageURL = root.appendingPathComponent("sources/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("Feature.bundle", isDirectory: true),
            withIntermediateDirectories: true
        )
        let moduleID = ModuleID("dev.example.feature")
        let manifest = PluginManifest(
            id: PluginID("dev.example.plugin"),
            displayName: "Example Plugin",
            version: version,
            hostCompatibility: PluginHostCompatibility(
                minimum: PluginVersion(major: 0, minor: 3, patch: 0),
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: PluginVendor(
                id: "dev.example",
                displayName: "Example",
                signatureRequirement: .sameTeamAsHost
            ),
            entrypoint: PluginEntrypoint(
                kind: .nativeBundle,
                bundleIdentifier: "dev.example.feature",
                principalClass: "ExamplePlugin",
                bundlePath: "Feature.bundle"
            ),
            modules: [PluginModuleDeclaration(manifest: ModuleManifest(
                id: moduleID,
                displayName: "Example Feature",
                scope: .application,
                defaultState: .disabled,
                activationPolicy: .onDemand,
                providedCapabilities: [ModuleCapabilityID("dev.example.feature.capability")],
                isRequired: required
            ))],
            languageSupports: languageSupport.map { [$0] } ?? []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("plugin.json"),
            options: .atomic
        )
        return packageURL
    }
}

private final class PluginStartupConfigurationStore: ModuleConfigurationStore, @unchecked Sendable {
    private let enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    func enabledState(for moduleID: ModuleID) -> Bool? { enabled }
    func setEnabledState(_ enabled: Bool, for moduleID: ModuleID) {}
}

private final class PluginStartupRecoveryStore: ModuleRecoveryStore, @unchecked Sendable {
    private var pending: [ModuleID]
    private var quarantined: Set<ModuleID> = []

    init(pending: [ModuleID] = []) { self.pending = pending }
    func pendingActivation() -> ModuleID? { nil }
    func setPendingActivation(_ moduleID: ModuleID?) {}
    func isQuarantined(_ moduleID: ModuleID) -> Bool { quarantined.contains(moduleID) }
    func setQuarantined(_ quarantined: Bool, for moduleID: ModuleID) {
        if quarantined {
            self.quarantined.insert(moduleID)
        } else {
            self.quarantined.remove(moduleID)
        }
    }
    func pendingPluginLoadModules() -> [ModuleID] { pending }
    func setPendingPluginLoadModules(_ moduleIDs: [ModuleID]) { pending = moduleIDs }
}

private final class CountingPluginPrincipalClassLoader: PluginPrincipalClassLoading {
    private(set) var loadCount = 0
    func principalClass(at bundleURL: URL) throws -> AnyClass {
        loadCount += 1
        return NSObject.self
    }
}

private enum TestPluginSignatureError: Error, Equatable {
    case rejected
}

private final class TestPluginSignatureVerifier: PluginPackageSignatureVerifying, @unchecked Sendable {
    private let rejectedVersions: Set<PluginVersion>
    private(set) var verifiedVersions: [PluginVersion] = []

    init(rejectedVersions: Set<PluginVersion> = []) {
        self.rejectedVersions = rejectedVersions
    }

    func verify(packageAt packageURL: URL, manifest: PluginManifest) throws {
        verifiedVersions.append(manifest.version)
        if rejectedVersions.contains(manifest.version) {
            throw TestPluginSignatureError.rejected
        }
    }
}
