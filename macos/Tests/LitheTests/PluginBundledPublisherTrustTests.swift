import CryptoKit
import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheApplicationKernel
import LitheModuleAPI
import LithePluginPackageSigning
import Testing

/// Runs production validation, signature verification and package storage.
/// No fixture process executes, and all files belong to this test's root.
@MainActor
struct PluginBundledPublisherTrustTests {
    @Test(arguments: [true, false])
    func installingOverBundledCopyPreservesDefaultOrDisabledChoice(enabled: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferences = MigrationPreferences()
        let configuration = MacModuleConfigurationStore(store: preferences)
        let store = fixture.store()
        let initial = try store.scanInstalledPlugins().packages
        let moduleID = try #require(initial.first?.manifest.modules.first?.manifest.id)
        if !enabled { configuration.setEnabledState(false, for: moduleID) }
        let settings = InMemoryPluginSettings([OfficialPluginCatalog.javaPluginID.rawValue: ["saved": .string("retained")]])
        let manager = fixture.manager(store: store, configuration: configuration, packages: initial, settings: settings)
        let original = try fixture.digest(of: fixture.bundled)
        try fixture.sign(fixture.download)

        try manager.installPackage(at: fixture.download)

        #expect(configuration.enabledState(for: moduleID) == enabled)
        #expect(manager.snapshots.first?.isEnabled == enabled)
        #expect(manager.snapshots.first?.requiresRestart == true)
        #expect(settings.values(forPlugin: OfficialPluginCatalog.javaPluginID.rawValue)["saved"] == .string("retained"))
        try store.prepareForLaunch()
        let restarted = try store.scanInstalledPlugins()
        #expect(restarted.packages.count == 1)
        #expect(restarted.packages.first?.installation.origin == .marketplace)
        #expect(restarted.packages.first?.installation.status == .installed)
        #expect(try fixture.digest(of: fixture.bundled) == original)
    }

    @Test
    func migrationDoesNotEnableModulesThePreviousPackageDidNotOwn() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        try store.setBundledPluginRemoved(OfficialPluginCatalog.javaPluginID, removed: true)
        let configuration = MacModuleConfigurationStore(store: MigrationPreferences())
        let manager = fixture.manager(store: store, configuration: configuration, packages: try store.scanInstalledPlugins().packages)
        var object = fixture.manifest
        var languages = try #require(object["languages"] as? [[String: Any]])
        languages.append(["id": "future", "displayName": "Future", "fileExtensions": ["future"]])
        object["languages"] = languages
        object["activationEvents"] = ["onLanguage:fixture", "onLanguage:future"]
        var servers = try #require(object["languageServers"] as? [[String: Any]])
        var added = try #require(servers.first)
        added["languageID"] = "future"
        servers.append(added)
        object["languageServers"] = servers
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.download.appendingPathComponent("plugin.json"))
        try fixture.sign(fixture.download)

        try manager.installPackage(at: fixture.download)

        #expect(configuration.enabledState(for: .languageServerExtension("fixture")) == true)
        #expect(configuration.enabledState(for: .languageServerExtension("future")) == nil)
    }

    @Test
    func directUpgradeWithoutBundledCopyKeepsDisabledPreferenceAndRemovedState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(includeBundled: false)
        try store.setBundledPluginRemoved(OfficialPluginCatalog.javaPluginID, removed: true)
        try store.prepareForLaunch()
        #expect(try store.scanInstalledPlugins().packages.isEmpty)
        let configuration = MacModuleConfigurationStore(store: MigrationPreferences())
        let moduleID = try #require(DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: fixture.download.appendingPathComponent("plugin.json"))
        ).pluginManifest.modules.first?.manifest.id)
        configuration.setEnabledState(false, for: moduleID)
        let manager = fixture.manager(store: store, configuration: configuration, packages: [])
        try fixture.sign(fixture.download)
        try manager.installPackage(at: fixture.download)
        // An explicit disk install is allowed, but does not turn a disabled
        // module back on or let the old removal marker delete its state.
        let state = fixture.stateDirectories.pluginDirectory(pluginID: OfficialPluginCatalog.javaPluginID.rawValue)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let saved = state.appendingPathComponent("saved.json")
        try Data("user state".utf8).write(to: saved)
        try store.prepareForLaunch()
        #expect(configuration.enabledState(for: moduleID) == false)
        #expect(try Data(contentsOf: saved) == Data("user state".utf8))
        #expect(try store.scanInstalledPlugins().packages.count == 1)
    }

    @Test
    func uninstallingInstalledUpdateDoesNotResurrectBundledJava() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        try fixture.sign(fixture.download)
        _ = try store.installPackage(from: fixture.download)
        let configuration = MacModuleConfigurationStore(store: MigrationPreferences())
        let manager = fixture.manager(store: store, configuration: configuration, packages: try store.scanInstalledPlugins().packages)
        try await manager.uninstall(OfficialPluginCatalog.javaPluginID)
        try store.prepareForLaunch()
        let packages = try store.scanInstalledPlugins().packages
        #expect(packages.count == 1)
        #expect(packages.first?.installation.origin == .bundled)
        #expect(packages.first?.installation.status == .removed)
    }

    @Test
    func failedInstallPreservesBundledEnablementAndImmutableResources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = MacModuleConfigurationStore(store: MigrationPreferences())
        let store = fixture.store()
        let packages = try store.scanInstalledPlugins().packages
        let manager = fixture.manager(store: store, configuration: configuration, packages: packages)
        let moduleID = try #require(packages.first?.manifest.modules.first?.manifest.id)
        let before = try fixture.digest(of: fixture.bundled)
        #expect(throws: (any Error).self) { try manager.installPackage(at: fixture.download) }
        #expect(configuration.enabledState(for: moduleID) == nil)
        #expect(manager.snapshots.first?.isEnabled == true)
        #expect(manager.snapshots.first?.requiresRestart == false)
        #expect(try fixture.digest(of: fixture.bundled) == before)
    }

    @Test
    func missingJavaIsSuggestedOnlyWhenNeededAndNoPackageExists() {
        for name in ["Main.java", "pom.xml", "build.gradle", "build.gradle.kts"] {
            let files = [URL(fileURLWithPath: "/fixture/\(name)")]
            #expect(JavaPluginTransition.shouldSuggest(files: files, installedPluginIDs: []))
            #expect(!JavaPluginTransition.shouldSuggest(files: files, installedPluginIDs: [OfficialPluginCatalog.javaPluginID]))
        }
        #expect(!JavaPluginTransition.shouldSuggest(files: [URL(fileURLWithPath: "/fixture/README.md")], installedPluginIDs: []))
    }
    @Test
    func hostSealedCopyAndSignedInstalledUpdateUseOnePluginIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.digest(of: fixture.bundled)
        let initial = try fixture.store().scanInstalledPlugins()
        #expect(initial.issues.isEmpty)
        #expect(initial.packages.map(\.installation.origin) == [.bundled])

        try fixture.sign(fixture.download)
        let installed = try fixture.store().installPackage(from: fixture.download)
        let restarted = try fixture.store().scanInstalledPlugins()
        #expect(restarted.issues.isEmpty)
        #expect(restarted.packages.count == 1)
        #expect(restarted.packages.first?.packageURL.resolvingSymlinksInPath() == installed.packageURL.resolvingSymlinksInPath())
        #expect(restarted.packages.first?.installation.origin == .marketplace)
        #expect(try fixture.digest(of: fixture.bundled) == before)
        #expect(try fixture.digest(of: installed.packageURL) == fixture.digest(of: fixture.download))
    }

    @Test
    func unsignedOutsideCopyCannotClaimTheBundledTrustException() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for origin: PluginInstallationOrigin in [.marketplace, .bundled, .localDevelopment] {
            #expect(throws: (any Error).self) {
                _ = try fixture.store().verifyCandidatePackage(
                    at: fixture.download, origin: origin, marketplace: nil
                )
            }
        }
        #expect(try fixture.store().scanInstalledPlugins().packages.first?.installation.origin == .bundled)
    }

    @Test
    func presentInvalidSignatureIsRejectedEvenInsideTheHostSeal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sign(fixture.bundled)
        try Data("tampered".utf8).write(to: fixture.bundled.appendingPathComponent("server.jar"))
        let scan = try fixture.store().scanInstalledPlugins()
        #expect(scan.packages.isEmpty)
        #expect(scan.issues.count == 1)
    }

    @Test
    func installedRuntimeTamperingCannotFallBackToHostSeal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sign(fixture.download)
        let installed = try fixture.store().installPackage(from: fixture.download)
        try Data("tampered".utf8).write(to: installed.packageURL.appendingPathComponent("runtime/arm64/bin/java"))
        let scan = try fixture.store().scanInstalledPlugins()
        #expect(scan.issues.count == 1)
        // The damaged update is isolated; the immutable bundled source remains.
        #expect(scan.packages.map(\.installation.origin) == [.bundled])
    }

    @Test
    func officialPackageCannotChangeItsPinnedBundledTrust() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var manifest = fixture.manifest
        var vendor = try #require(manifest["vendor"] as? [String: Any])
        vendor.removeValue(forKey: "bundledSignatureRequirement")
        manifest["vendor"] = vendor
        var requires = try #require(manifest["requires"] as? [String: Int])
        requires.removeValue(forKey: "packageTrust")
        manifest["requires"] = requires
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.download.appendingPathComponent("plugin.json"))
        try fixture.sign(fixture.download)
        #expect(throws: PluginPackageStoreError.officialSignatureRequirementMismatch(OfficialPluginCatalog.javaPluginID)) {
            _ = try fixture.store().installPackage(from: fixture.download)
        }
    }

    @Test
    func signedPackageMissingTheHostArchitectureRuntimeIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let arch = MacPluginLanguageServerLaunchResolver.hostArchitecture
        try FileManager.default.removeItem(at: fixture.download.appendingPathComponent("runtime/\(arch)/bin/java"))
        try fixture.sign(fixture.download)
        #expect(throws: (any Error).self) {
            _ = try fixture.store().installPackage(from: fixture.download)
        }
        #expect(try fixture.store().scanInstalledPlugins().packages.map(\.installation.origin) == [.bundled])
    }

    private struct Fixture {
        let root: URL
        let host: URL
        let bundled: URL
        let download: URL
        let manifest: [String: Any]
        let privateKey: Curve25519.Signing.PrivateKey

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-publisher-bundled-\(UUID().uuidString)")
            host = root.appendingPathComponent("Lithe.app")
            bundled = host.appendingPathComponent("Contents/Resources/OfficialPlugins/dev.lithe.plugin.java-support")
            download = root.appendingPathComponent("download/dev.lithe.plugin.java-support")
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
            let url = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/publisher-bundled.plugin.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["id"] = OfficialPluginCatalog.javaPluginID.rawValue
            manifest = object
            do {
                for package in [bundled, download] {
                    try DeclarativePluginTestSupport.writePackage(at: package, manifest: manifest)
                    for arch in ["arm64", "x86_64"] {
                        let java = package.appendingPathComponent("runtime/\(arch)/bin/java")
                        try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data("fixture runtime".utf8).write(to: java)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
                    }
                    try Data("fixture server".utf8).write(to: package.appendingPathComponent("server.jar"))
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        var stateDirectories: MacPluginStateDirectories { MacPluginStateDirectories(rootURL: root.appendingPathComponent("state")) }

        func store(includeBundled: Bool = true) -> MacPluginPackageStore {
            MacPluginPackageStore(
                rootURL: root.appendingPathComponent("installed"),
                bundledRootURL: includeBundled ? bundled.deletingLastPathComponent() : nil,
                stateDirectories: stateDirectories,
                validator: DeclarativePluginTestSupport.operations,
                verifier: MacOfficialPluginSignatureVerifier(
                    trustedPublisherKeys: [PluginPackageSignature.keyID: privateKey.publicKey],
                    allowsLocalDevelopmentPackages: false,
                    hostBundleURL: host
                )
            )
        }

        @MainActor
        func manager(
            store: MacPluginPackageStore,
            configuration: MacModuleConfigurationStore,
            packages: [InstalledPluginPackage],
            settings: any PluginSettingsStoring = InMemoryPluginSettings()
        ) -> MacPluginManager {
            MacPluginManager(
                packageStore: store,
                moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
                configurationStore: configuration,
                settings: settings,
                launchMode: .normal,
                startup: MacPluginStartupResult(installedPlugins: packages, registeredPlugins: [], issues: []),
                allowsLocalDevelopmentPackages: false
            )
        }

        func sign(_ package: URL) throws {
            let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
            let document = try PluginPackageSignature.makeDocument(
                packageAt: package,
                pluginID: descriptor.id.rawValue,
                pluginVersion: descriptor.pluginManifest.version.description,
                privateKey: privateKey
            )
            try PluginPackageSignature.write(document, to: package)
        }

        func digest(of package: URL) throws -> String {
            try PluginPackageSignature.contentDigest(packageAt: package, fileManager: FileManager.default)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class MigrationPreferences: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
