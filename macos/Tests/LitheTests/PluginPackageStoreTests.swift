import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI
import Testing

struct PluginPackageStoreTests {
    @Test
    func bundledOfficialPluginIsVisibleWithoutAUserInstallation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        try makePackage(
            at: bundledRoot.appendingPathComponent("dev.example.plugin", isDirectory: true),
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let store = makeStore(root: root, bundledRoot: bundledRoot)

        let plugin = try #require(try store.installedPlugins().first)

        #expect(plugin.installation.origin == .bundled)
        #expect(plugin.manifest.version == PluginVersion(major: 0, minor: 3, patch: 0))
        #expect(plugin.manifest.entrypoint == .declarative)
    }

    @Test
    func validUserUpdateOverridesBundledVersion() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        try makePackage(
            at: bundledRoot.appendingPathComponent("dev.example.plugin", isDirectory: true),
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let store = makeStore(root: root, bundledRoot: bundledRoot)
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
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = TestPluginSignatureVerifier()
        let store = makeStore(root: root, verifier: verifier)
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
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "valid",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        ))
        try FileManager.default.createDirectory(
            at: installedRoot(root).appendingPathComponent("dev.example.broken", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = try store.scanInstalledPlugins()

        #expect(result.packages.map(\.manifest.id) == [PluginID("dev.example.plugin")])
        #expect(result.issues.count == 1)
    }

    @Test
    func damagedPackageCanBeRemovedWithoutReadingItsManifest() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
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
    func retiredLinuxDoPackageCannotBeLoadedOrReinstalled() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let retiredID = PluginID("dev.lithe.plugin.linux-do-support")
        let version = PluginVersion(major: 0, minor: 3, patch: 0)
        let source = try makePackage(
            root: root,
            name: "retired-linux-do",
            version: version,
            pluginID: retiredID
        )
        let store = makeStore(root: root)

        #expect(throws: PluginPackageStoreError.retiredPlugin(retiredID)) {
            try store.installPackage(from: source)
        }

        // Simulate a package installed by an older Lithe release.
        try placeInstalledPackage(source, root: root, pluginID: retiredID, version: version)

        let scan = try store.scanInstalledPlugins()
        #expect(scan.packages.isEmpty)
        #expect(scan.issues.map(\.pluginID) == [retiredID])
    }

    @Test
    func rejectedUpdateLeavesCurrentVersionActive() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let versionOne = PluginVersion(major: 0, minor: 3, patch: 0)
        let versionTwo = PluginVersion(major: 0, minor: 3, patch: 1)
        let store = makeStore(root: root, verifier: TestPluginSignatureVerifier(rejectedVersions: [versionTwo]))
        let firstSource = try makePackage(root: root, name: "first", version: versionOne)
        let secondSource = try makePackage(root: root, name: "second", version: versionTwo)

        _ = try store.installPackage(from: firstSource)
        var invalidated: [PluginID] = []
        #expect(throws: TestPluginSignatureError.rejected) {
            _ = try store.installPackage(from: secondSource, beforeReplacingPackage: { invalidated.append($0) })
        }
        #expect(invalidated.isEmpty)
        #expect(throws: PluginPackageStoreError.rollbackUnavailable(PluginID("dev.example.plugin"))) {
            _ = try store.rollback(PluginID("dev.example.plugin"), beforeReplacingPackage: { invalidated.append($0) })
        }
        #expect(invalidated.isEmpty)

        let installed = try #require(try store.installedPlugins().first)
        #expect(installed.manifest.version == versionOne)
        #expect(installed.installation.previousVersion == nil)
    }

    @Test
    func reinstallCanReplaceTheActiveVersionOnlyAfterValidation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let version = PluginVersion(major: 0, minor: 3, patch: 0)
        let store = makeStore(root: root)
        _ = try store.installPackage(from: makePackage(root: root, name: "first", version: version))
        let replacement = try makePackage(root: root, name: "replacement", version: version)

        #expect(throws: PluginPackageStoreError.versionAlreadyInstalled(version)) {
            _ = try store.installPackage(from: replacement)
        }
        var invalidated: [PluginID] = []
        let current = try #require(try store.installedPlugins().first)
        let oldManifestURL = current.packageURL.appendingPathComponent("plugin.json")
        let oldManifest = try Data(contentsOf: oldManifestURL)
        let reinstalled = try store.installPackage(
            from: replacement,
            deferActivationUntilRestart: true,
            replaceExisting: true,
            beforeReplacingPackage: { id in
                invalidated.append(id)
                // The callback must precede the move of the active package.
                #expect((try? Data(contentsOf: oldManifestURL)) == oldManifest)
            }
        )

        #expect(invalidated == [PluginID("dev.example.plugin")])
        #expect(reinstalled.installation.activeVersion == version)
        #expect(reinstalled.installation.previousVersion == nil)
        #expect(reinstalled.installation.status == .updateStaged)
        #expect(try store.installedPlugins().first?.manifest.version == version)
    }

    @Test
    func officialPublisherPackageCannotDowngradeSignatureRequirement() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = TestPluginSignatureVerifier()
        let store = makeStore(root: root, verifier: verifier)
        let package = try DeclarativePluginTestSupport.writeOfficialPackage(
            "PhpSupport",
            at: root.appendingPathComponent("sources/downgraded-policy", isDirectory: true)
        ) { manifest in
            var vendor = manifest["vendor"] as? [String: Any] ?? [:]
            vendor["signatureRequirement"] = "sameTeamAsHost"
            manifest["vendor"] = vendor
        }

        #expect(throws: PluginPackageStoreError.officialSignatureRequirementMismatch(
            OfficialPluginCatalog.phpPluginID
        )) {
            _ = try store.installPackage(from: package)
        }
        #expect(verifier.verifiedVersions.isEmpty)
    }

    @Test
    func refusedDeclarationReportsItsStableCode() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var manifest = DeclarativePluginTestSupport.manifestObject(version: PluginVersion(major: 0, minor: 3, patch: 0))
        manifest["permissions"] = ["network.fetch"]
        let package = try DeclarativePluginTestSupport.writePackage(
            at: root.appendingPathComponent("sources/unknown-permission", isDirectory: true),
            manifest: manifest
        )

        do {
            _ = try store.installPackage(from: package)
            Issue.record("A manifest with an unknown permission must be refused")
        } catch PluginPackageStoreError.declarationRejected(let pluginID, let rejection) {
            #expect(pluginID == PluginID("dev.example.plugin"))
            #expect(rejection.code == "plugin.permission.unknown")
        }
    }

    @Test
    func missingPackagedLanguageServerIsRefused() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let package = try makePackage(
            root: root,
            name: "missing-launcher",
            version: PluginVersion(major: 0, minor: 3, patch: 0),
            packagedLauncher: "language-server/bin/fixture"
        )
        try FileManager.default.removeItem(at: package.appendingPathComponent("language-server/bin/fixture"))

        #expect(throws: PluginPackageStoreError.invalidInstalledPlugin(
            PluginID("dev.example.plugin"),
            PluginPackageStoreError.languageServerLaunchMissing(
                PluginID("dev.example.plugin"),
                "language-server/bin/fixture"
            ).localizedDescription
        )) {
            _ = try store.installPackage(from: package)
        }
    }

    @Test
    func packagedLanguageServerMayNotBeASymbolicLink() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let package = try makePackage(
            root: root,
            name: "linked-launcher",
            version: PluginVersion(major: 0, minor: 3, patch: 0),
            packagedLauncher: "language-server/bin/fixture"
        )
        let launcher = package.appendingPathComponent("language-server/bin/fixture")
        try FileManager.default.removeItem(at: launcher)
        try FileManager.default.createSymbolicLink(atPath: launcher.path, withDestinationPath: "/bin/sh")

        #expect(throws: PluginPackageStoreError.self) {
            _ = try store.installPackage(from: package)
        }
    }

    /// A provider's packaged executable is checked at installation, like a
    /// language server's: it must be a regular, executable file reached
    /// without a symbolic link, or the package is refused before its first
    /// model load could fail.
    @Test(arguments: ["missing", "notExecutable", "symbolicLink"])
    func unusablePackagedBuildProviderIsRefused(_ defect: String) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let package = try makeProviderPackage(root: root, launch: ["kind": "packaged", "path": "provider/bin/provider"])
        let executable = package.appendingPathComponent("provider/bin/provider")
        switch defect {
        case "missing":
            try FileManager.default.removeItem(at: executable)
        case "notExecutable":
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        default:
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/sh")
        }

        let pluginID = PluginID("dev.lithe.fixture.gradle-provider")
        #expect(throws: PluginPackageStoreError.invalidInstalledPlugin(
            pluginID,
            PluginPackageStoreError.buildProviderLaunchMissing(
                pluginID, buildSystemID: "gradle", path: "provider/bin/provider"
            ).localizedDescription
        )) {
            _ = try store.installPackage(from: package)
        }
    }

    /// A runtime launch needs its packaged entry; the runtime itself is
    /// discovered on the machine and is not part of the package.
    @Test
    func buildProviderRuntimeEntryMustBeInThePackage() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let package = try makeProviderPackage(root: root, launch: nil)

        #expect(throws: PluginPackageStoreError.self) {
            _ = try store.installPackage(from: package)
        }

        let entry = package.appendingPathComponent("provider/gradle-tooling-provider.jar")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: entry)
        try Data().write(to: package.appendingPathComponent("provider/lithe-model.init.gradle"))
        let installed = try store.installPackage(from: package)
        #expect(installed.descriptor.buildSystems.map(\.declaresProvider) == [true])
    }

    /// A plugin inside the application replaces a built-in feature, so it has
    /// to work on first launch. A downloaded plugin stays off until enabled.
    @Test
    func bundledPluginIsEnabledByDefaultAndAnInstalledOneIsNot() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        let version = PluginVersion(major: 0, minor: 3, patch: 0)
        try makePackage(
            at: bundledRoot.appendingPathComponent("dev.example.bundled", isDirectory: true),
            version: version,
            pluginID: PluginID("dev.example.bundled"),
            languageID: "bundled"
        )
        let store = makeStore(root: root, bundledRoot: bundledRoot)
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "downloaded",
            version: version,
            pluginID: PluginID("dev.example.downloaded"),
            languageID: "downloaded"
        ))

        let plugins = Dictionary(uniqueKeysWithValues: try store.installedPlugins().map { ($0.manifest.id.rawValue, $0) })

        #expect(plugins["dev.example.bundled"]?.manifest.modules.map(\.manifest.defaultState) == [.enabled])
        #expect(plugins["dev.example.downloaded"]?.manifest.modules.map(\.manifest.defaultState) == [.disabled])
    }

    /// The app bundle is read-only, so removing a bundled plugin is recorded
    /// outside it. The package stays listed for restoring, nothing inside the
    /// bundle changes, and its state outlives the running server until the
    /// next launch.
    @Test
    func aBundledPluginCanBeRemovedAndRestoredWithoutTouchingTheBundle() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        let pluginID = PluginID("dev.example.plugin")
        try makePackage(
            at: bundledRoot.appendingPathComponent(pluginID.rawValue, isDirectory: true),
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let directories = MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let state = directories.stateDirectory(pluginID: pluginID.rawValue, languageID: "fixture")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = makeStore(root: root, bundledRoot: bundledRoot, stateDirectories: directories)
        let bundleFilesBefore = try FileManager.default.subpathsOfDirectory(atPath: bundledRoot.path).sorted()

        try store.setBundledPluginRemoved(pluginID, removed: true)

        let removed = try #require(try store.installedPlugins().first)
        #expect(removed.installation.status == .removed)
        #expect(removed.installation.origin == .bundled)
        let stateDirectory = directories.pluginDirectory(pluginID: pluginID.rawValue)
        // The server is still running until restart, so its state stays.
        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: bundledRoot.path).sorted() == bundleFilesBefore)
        // The record survives a relaunch, it is not mistaken for an
        // installation, and the relaunch is when the state is deleted.
        try store.prepareForLaunch()
        #expect(try makeStore(root: root, bundledRoot: bundledRoot).installedPlugins().first?.installation.status == .removed)
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))

        try store.setBundledPluginRemoved(pluginID, removed: false)
        #expect(try store.installedPlugins().first?.installation.status == .installed)
    }

    /// A damaged removal record must not take the application down or be
    /// silently overwritten: the plugin reads as installed, and the next
    /// removal keeps the damaged file aside.
    @Test
    func anUnreadableRemovalRecordIsKeptAsideAndNeverBlocksRemoval() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        let pluginID = PluginID("dev.example.plugin")
        try makePackage(
            at: bundledRoot.appendingPathComponent(pluginID.rawValue, isDirectory: true),
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let store = makeStore(root: root, bundledRoot: bundledRoot)
        let pluginRoot = installedRoot(root)
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        let record = pluginRoot.appendingPathComponent(".removed-bundled-plugins.json")
        try Data("{ not json".utf8).write(to: record)

        #expect(try store.installedPlugins().first?.installation.status == .installed)

        try store.setBundledPluginRemoved(pluginID, removed: true)

        #expect(try store.installedPlugins().first?.installation.status == .removed)
        let kept = pluginRoot.appendingPathComponent(".removed-bundled-plugins.json.unreadable")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ not json")
    }

    /// Restoring before the restart that completes a removal must not cost
    /// the user the index of a server that never stopped.
    @Test
    func restoringARemovedBundledPluginBeforeRelaunchKeepsItsState() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        let pluginID = PluginID("dev.example.plugin")
        try makePackage(
            at: bundledRoot.appendingPathComponent(pluginID.rawValue, isDirectory: true),
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let directories = MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let state = directories.stateDirectory(pluginID: pluginID.rawValue, languageID: "fixture")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = makeStore(root: root, bundledRoot: bundledRoot, stateDirectories: directories)

        try store.setBundledPluginRemoved(pluginID, removed: true)
        try store.setBundledPluginRemoved(pluginID, removed: false)
        try store.prepareForLaunch()

        #expect(FileManager.default.fileExists(atPath: state.path))
    }

    @Test
    func deferredUpdateAndUninstallCompleteAtNextLaunch() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
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

    @Test
    func uninstallRemovesThePHPPluginLanguageServerWithItsOwner() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let package = try DeclarativePluginTestSupport.writeOfficialPackage(
            "PhpSupport",
            at: root.appendingPathComponent("sources/php", isDirectory: true)
        )

        let installed = try store.installPackage(from: package)
        let launcher = installed.packageURL.appendingPathComponent("language-server/bin/intelephense")
        #expect(FileManager.default.isExecutableFile(atPath: launcher.path))
        #expect(installed.descriptor.languageServers.first?.executableNames == ["intelephense"])

        try store.stageUninstall(installed.manifest.id)
        try store.prepareForLaunch()

        #expect(!FileManager.default.fileExists(atPath: installed.packageURL.path))
        #expect(try store.installedPlugins().isEmpty)
    }

    /// Language-server state lives outside the package, so removing the
    /// package directory alone would leave indexes behind.
    @Test
    func uninstallRemovesThePluginsLanguageServerState() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let store = makeStore(root: root, stateDirectories: directories)
        let version = PluginVersion(major: 0, minor: 3, patch: 0)
        func writeState(for plugin: InstalledPluginPackage) throws -> URL {
            let state = directories.stateDirectory(pluginID: plugin.manifest.id.rawValue, languageID: "fixture")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("index".utf8).write(to: state.appendingPathComponent("index"))
            return directories.pluginDirectory(pluginID: plugin.manifest.id.rawValue)
        }

        let immediate = try store.installPackage(from: makePackage(root: root, name: "one", version: version))
        let immediateState = try writeState(for: immediate)
        try store.uninstall(immediate.manifest.id)
        #expect(!FileManager.default.fileExists(atPath: immediateState.path))

        // A staged uninstall keeps the state until the package itself goes.
        let staged = try store.installPackage(from: makePackage(root: root, name: "two", version: version))
        let stagedState = try writeState(for: staged)
        try store.stageUninstall(staged.manifest.id)
        #expect(FileManager.default.fileExists(atPath: stagedState.path))
        try store.prepareForLaunch()
        #expect(!FileManager.default.fileExists(atPath: stagedState.path))
    }

    /// An installed schema-1 native PHP package is reported as needing an
    /// update, is never accepted, and cannot be restored by rollback once
    /// the declarative package replaces it.
    @Test
    func legacyNativePHPPackageIsReplacedAndCannotBeRolledBackTo() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let legacyVersion = PluginVersion(major: 0, minor: 3, patch: 0)
        let legacy = root.appendingPathComponent("sources/legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(Self.legacyNativePHPManifest.utf8).write(to: legacy.appendingPathComponent("plugin.json"))
        try placeInstalledPackage(
            legacy,
            root: root,
            pluginID: OfficialPluginCatalog.phpPluginID,
            version: legacyVersion
        )

        let scan = try store.scanInstalledPlugins()
        #expect(scan.packages.isEmpty)
        #expect(scan.issues == [PluginPackageScanIssue(
            pluginID: OfficialPluginCatalog.phpPluginID,
            message: PluginPackageStoreError.legacyNativePackage(
                OfficialPluginCatalog.phpPluginID,
                legacyVersion
            ).localizedDescription
        )])
        #expect(throws: PluginPackageStoreError.legacyNativePackage(OfficialPluginCatalog.phpPluginID, legacyVersion)) {
            _ = try store.installPackage(from: legacy)
        }

        let replacement = try DeclarativePluginTestSupport.writeOfficialPackage(
            "PhpSupport",
            at: root.appendingPathComponent("sources/replacement", isDirectory: true)
        )
        let installed = try store.installPackage(
            from: replacement,
            deferActivationUntilRestart: true,
            replaceExisting: true
        )
        #expect(installed.installation.previousVersion == legacyVersion)
        #expect(throws: PluginPackageStoreError.legacyNativePackage(OfficialPluginCatalog.phpPluginID, legacyVersion)) {
            _ = try store.rollback(OfficialPluginCatalog.phpPluginID)
        }
        try store.prepareForLaunch()
        #expect(try store.installedPlugins().map(\.manifest.entrypoint) == [.declarative])
    }

    @Test
    func sameTeamPackageIsTrustedOnlyInsideTheHostBundle() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostBundle = root.appendingPathComponent("Lithe.app", isDirectory: true)
        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: [:],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: hostBundle
        )
        let inside = try makePackage(
            at: hostBundle.appendingPathComponent("Contents/Resources/OfficialPlugins/dev.example.plugin", isDirectory: true),
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        )
        let outside = try makePackage(root: root, name: "outside", version: PluginVersion(major: 0, minor: 3, patch: 0))
        let manifest = try DeclarativePluginTestSupport.descriptor(
            DeclarativePluginTestSupport.manifestObject(version: PluginVersion(major: 0, minor: 3, patch: 0))
        ).pluginManifest

        try verifier.verify(packageAt: inside, manifest: manifest, origin: .bundled)
        #expect(throws: PluginPackageStoreError.hostSealRequired(manifest.id)) {
            try verifier.verify(packageAt: outside, manifest: manifest, origin: .marketplace)
        }
        // A bundled origin claimed for a package outside the bundle is refused.
        #expect(throws: PluginPackageStoreError.hostSealRequired(manifest.id)) {
            try verifier.verify(packageAt: outside, manifest: manifest, origin: .bundled)
        }
    }

    /// Declarative plugins run no code in the process, so a native-load
    /// marker left by an older release is cleared instead of quarantining the
    /// modules that replaced the native package.
    @MainActor
    @Test
    func leftoverNativeLoadMarkerIsClearedWithoutQuarantine() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "recover",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        ))
        let moduleID = ModuleID.languageServerExtension("fixture")
        let recovery = PluginStartupRecoveryStore(pending: [moduleID])

        let result = MacPluginStartupLoader.withHostUIValidation(packageStore: store).load(recoveryStore: recovery)

        #expect(result.registeredPlugins.map(\.manifest.id) == [PluginID("dev.example.plugin")])
        #expect(!recovery.isQuarantined(moduleID))
        #expect(recovery.pendingPluginLoadModules().isEmpty)
    }

    @MainActor
    @Test
    func disabledLanguagePluginIsRegisteredWithoutLoadingCode() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "disabled-language",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        ))

        let result = MacPluginStartupLoader.withHostUIValidation(packageStore: store).load(recoveryStore: nil)

        // Registration only offers host-owned modules; enablement still
        // decides whether they may activate.
        #expect(result.registeredManifests.map(\.id) == [PluginID("dev.example.plugin")])
        #expect(result.registeredManifests.flatMap(\.modules).allSatisfy {
            $0.manifest.defaultState == .disabled
        })
        #expect(result.installedLanguageSupports.map(\.id) == ["fixture"])
    }

    @MainActor
    @Test
    func pluginClaimingABundledLanguageIsRejectedAtStartup() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "python-clash",
            version: PluginVersion(major: 0, minor: 3, patch: 0),
            languageID: "python"
        ))

        let result = MacPluginStartupLoader.withHostUIValidation(packageStore: store).load(recoveryStore: nil)

        #expect(result.registeredPlugins.isEmpty)
        #expect(result.issues.map(\.pluginID) == [PluginID("dev.example.plugin")])
    }

    @MainActor
    @Test
    func packageWhoseUIFailsHostValidationIsRejectedAtStartup() throws {
        struct Rejected: Error, LocalizedError { var errorDescription: String? { "ui rejected" } }
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try store.installPackage(from: makePackage(
            root: root,
            name: "ui-rejected",
            version: PluginVersion(major: 0, minor: 3, patch: 0)
        ))

        let result = MacPluginStartupLoader(packageStore: store, validateUI: { _ in throw Rejected() }).load(recoveryStore: nil)

        #expect(result.registeredPlugins.isEmpty)
        #expect(result.installedPlugins.map(\.manifest.id) == [PluginID("dev.example.plugin")])
        #expect(result.issues.map(\.message) == ["ui rejected"])
    }

    // MARK: Fixtures

    private static let legacyNativePHPManifest = """
    {
      "schemaVersion": 1,
      "id": "dev.lithe.plugin.php-support",
      "displayName": "PHP Support",
      "version": "0.3.0",
      "apiVersion": 1,
      "hostCompatibility": { "minimum": "0.3.0", "maximumExclusive": "0.4.0" },
      "vendor": { "id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "publisherPackage" },
      "entrypoint": {
        "kind": "nativeBundle",
        "bundleIdentifier": "dev.lithe.plugin.php-support.bundle",
        "principalClass": "LithePhpSupportPluginEntrypoint",
        "bundlePath": "PhpSupport.bundle"
      },
      "modules": []
    }
    """

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func installedRoot(_ root: URL) -> URL {
        root.appendingPathComponent("installed", isDirectory: true)
    }

    private func makeStore(
        root: URL,
        bundledRoot: URL? = nil,
        stateDirectories: MacPluginStateDirectories? = nil,
        verifier: any PluginPackageSignatureVerifying = TestPluginSignatureVerifier()
    ) -> MacPluginPackageStore {
        MacPluginPackageStore(
            rootURL: installedRoot(root),
            bundledRootURL: bundledRoot,
            stateDirectories: stateDirectories,
            validator: DeclarativePluginTestSupport.operations,
            verifier: verifier
        )
    }

    @discardableResult
    private func makePackage(
        at packageURL: URL,
        version: PluginVersion,
        pluginID: PluginID = PluginID("dev.example.plugin"),
        languageID: String = "fixture",
        packagedLauncher: String? = nil
    ) throws -> URL {
        try DeclarativePluginTestSupport.writePackage(
            at: packageURL,
            manifest: DeclarativePluginTestSupport.manifestObject(
                id: pluginID.rawValue,
                version: version,
                languageID: languageID,
                packagedLauncher: packagedLauncher
            )
        )
    }

    private func makePackage(
        root: URL,
        name: String,
        version: PluginVersion,
        pluginID: PluginID = PluginID("dev.example.plugin"),
        languageID: String = "fixture",
        packagedLauncher: String? = nil
    ) throws -> URL {
        try makePackage(
            at: root.appendingPathComponent("sources/\(name)", isDirectory: true),
            version: version,
            pluginID: pluginID,
            languageID: languageID,
            packagedLauncher: packagedLauncher
        )
    }

    /// The Gradle provider fixture, with its provider launch replaced when
    /// `launch` is given. A packaged launch gets an executable script.
    private func makeProviderPackage(root: URL, launch: [String: Any]?) throws -> URL {
        let fixtureURL = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/gradle-provider.plugin.json")
        var manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        if let launch {
            var buildSystems = try #require(manifest["buildSystems"] as? [[String: Any]])
            buildSystems[0]["provider"] = [
                "launch": launch,
                "arguments": ["--stdio"],
                "executesProjectCode": true,
                "mayUseNetwork": true
            ] as [String: Any]
            manifest["buildSystems"] = buildSystems
        }
        let package = try DeclarativePluginTestSupport.writePackage(
            at: root.appendingPathComponent("sources/provider", isDirectory: true),
            manifest: manifest
        )
        if launch?["kind"] as? String == "packaged", let path = launch?["path"] as? String {
            let executable = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return package
    }

    /// Writes a package directly into the installed layout, as an earlier
    /// Lithe release would have left it.
    private func placeInstalledPackage(
        _ source: URL,
        root: URL,
        pluginID: PluginID,
        version: PluginVersion
    ) throws {
        let pluginDirectory = installedRoot(root).appendingPathComponent(pluginID.rawValue, isDirectory: true)
        let versionDirectory = pluginDirectory
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version.description, isDirectory: true)
        try FileManager.default.createDirectory(
            at: versionDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: versionDirectory)
        try JSONEncoder().encode(PluginInstallationRecord(
            pluginID: pluginID,
            activeVersion: version,
            origin: .marketplace
        )).write(to: pluginDirectory.appendingPathComponent("installation.json"))
    }
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

private enum TestPluginSignatureError: Error, Equatable {
    case rejected
}

private final class TestPluginSignatureVerifier: PluginPackageSignatureVerifying, @unchecked Sendable {
    private let rejectedVersions: Set<PluginVersion>
    private(set) var verifiedVersions: [PluginVersion] = []

    init(rejectedVersions: Set<PluginVersion> = []) {
        self.rejectedVersions = rejectedVersions
    }

    func verify(
        packageAt packageURL: URL,
        manifest: PluginManifest,
        origin: PluginInstallationOrigin
    ) throws {
        verifiedVersions.append(manifest.version)
        if rejectedVersions.contains(manifest.version) {
            throw TestPluginSignatureError.rejected
        }
    }
}

extension MacPluginStartupLoader {
    /// Mirrors the production composition: validate against the real host UI bindings.
    @MainActor
    static func withHostUIValidation(packageStore: MacPluginPackageStore) -> MacPluginStartupLoader {
        MacPluginStartupLoader(packageStore: packageStore, validateUI: { _ = try WorkbenchModuleUIComposition.registry(for: $0) })
    }
}
