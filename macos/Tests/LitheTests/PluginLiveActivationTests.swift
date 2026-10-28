import Combine
import Foundation
@testable import Lithe
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import Testing

/// Plugins whose every contribution has a runtime backend take effect without
/// restarting Lithe. These tests cover which plugins qualify, the in-memory
/// registry, and the manager flows that feed it.
@Suite("Plugin live activation")
@MainActor
struct PluginLiveActivationTests {
    private static let pluginID = PluginID("dev.example.debugger")

    // MARK: - Which plugins qualify

    @Test
    func aDebugOnlyPluginActivatesWithoutARestart() throws {
        let descriptor = try DeclarativePluginTestSupport.descriptor(Self.debugManifest())
        #expect(descriptor.canActivateWithoutRestart)
    }

    @Test
    func aDebugPluginWithSettingsStillActivatesWithoutARestart() throws {
        var manifest = Self.debugManifest()
        manifest["requires"] = ["debugAdapters": 1, "languages": 1, "serverProcess": 1, "settings": 2]
        manifest["settings"] = [[
            "id": "program",
            "type": "file",
            "title": "Program",
            "default": "",
            "scope": "project",
            "effect": "nextRun"
        ]]
        let descriptor = try DeclarativePluginTestSupport.descriptor(manifest)
        #expect(!descriptor.settings.isEmpty)
        #expect(descriptor.canActivateWithoutRestart)
    }

    @Test
    func aDebugPluginThatAlsoBringsALanguageServerNeedsARestart() throws {
        var manifest = Self.debugManifest()
        manifest["permissions"] = ["debug.launch", "languageServer.launch"]
        manifest["requires"] = ["debugAdapters": 1, "languages": 1, "serverProcess": 1, "languageServers": 1]
        manifest["activationEvents"] = ["onDebug:lldb", "onLanguage:rust"]
        manifest["languageServers"] = [[
            "languageID": "rust",
            "launch": ["kind": "systemCommand", "commands": ["example-language-server"]]
        ]]
        let descriptor = try DeclarativePluginTestSupport.descriptor(manifest)
        #expect(!descriptor.debugAdapters.isEmpty)
        #expect(!descriptor.canActivateWithoutRestart)
    }

    /// The catalog visits plugins in ID order, so a debugger whose ID sorts
    /// before the language package must not take the language over.
    @Test(arguments: ["com.example.debugger", "io.example.debugger"])
    func aDebugOnlyLanguageNeverTakesOwnershipWhateverTheIDOrder(_ pluginID: String) throws {
        let descriptor = try DeclarativePluginTestSupport.descriptor(Self.debugManifest(id: pluginID))
        let catalog = try ValidatedPluginCatalog(
            manifests: BundledLanguagePluginCatalog.manifests + [descriptor.pluginManifest],
            hostVersion: BuiltInPluginCatalog.hostVersion
        )
        #expect(catalog.languageSupports["rust"]?.pluginID == PluginID("dev.lithe.plugin.rust-support"))
    }

    @Test(arguments: [
        "language-packaged-server", "language-system-command", "build-provider",
        "vcs-provider", "hello-lithe", "project-generator"
    ])
    func pluginsWithOtherContributionsStillNeedARestart(_ fixture: String) throws {
        let url = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/\(fixture).plugin.json")
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: Data(contentsOf: url))
        #expect(!descriptor.canActivateWithoutRestart)
    }

    // MARK: - Registry content

    @Test
    func onlyInstalledPackagesThatQualifyAreAdopted() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let live = try fixture.package(Self.debugManifest())
        let staged = try fixture.package(
            Self.debugManifest(id: "dev.example.staged", adapterID: "staged"),
            status: .updateStaged
        )
        let needsRestart = try fixture.package(DeclarativePluginTestSupport.manifestObject(
            id: "dev.example.language",
            version: PluginVersion(major: 1, minor: 0, patch: 0),
            signatureRequirement: .publisherPackage
        ))

        fixture.registry.apply([live, staged, needsRestart])

        #expect(Set(fixture.registry.snapshot.entries.keys) == [Self.pluginID])
    }

    @Test
    func generationAdvancesOnlyWhenTheRegistrationsChange() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.package(Self.debugManifest())
        let second = try fixture.package(Self.debugManifest(version: PluginVersion(major: 0, minor: 2, patch: 0)))
        var changes = 0
        let subscription = fixture.registry.changes.sink { changes += 1 }
        defer { subscription.cancel() }

        fixture.registry.apply([first])
        #expect(fixture.registry.snapshot.generation == 1)
        fixture.registry.apply([first])
        #expect(fixture.registry.snapshot.generation == 1)
        fixture.registry.apply([second])
        #expect(fixture.registry.snapshot.generation == 2)
        fixture.registry.apply([])
        #expect(fixture.registry.snapshot.generation == 3)
        fixture.registry.apply([])
        #expect(fixture.registry.snapshot.generation == 3)
        #expect(changes == 3)
    }

    @Test
    func aDisabledPluginStaysRegisteredButContributesNothing() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        fixture.isEnabled = false
        fixture.registry.apply([try fixture.package(Self.debugManifest())])

        let disabled = fixture.registry.snapshot
        #expect(disabled.entries[Self.pluginID]?.isEnabled == false)
        #expect(disabled.activePackages.isEmpty)
        #expect(disabled.debugAdapters.isEmpty)
        #expect(disabled.languageSupports.isEmpty)

        fixture.isEnabled = true
        fixture.registry.refreshEnablement()

        let enabled = fixture.registry.snapshot
        #expect(enabled.generation == disabled.generation + 1)
        #expect(enabled.debugAdapters["rust"]?.adapter.id == "lldb")
        #expect(enabled.languageSupports.map(\.id) == ["rust"])
        #expect(enabled.languageSupports.allSatisfy { $0.isDebugOnly })
    }

    @Test
    func theFirstPluginInIDOrderDebugsALanguageAndJavaKeepsTheHostAdapter() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let later = try fixture.package(Self.debugManifest(
            id: "dev.example.zeta", adapterID: "zeta", languageIDs: ["rust", "java"]
        ))
        let earlier = try fixture.package(Self.debugManifest(
            id: "dev.example.alpha", adapterID: "alpha", languageIDs: ["rust", "zig"]
        ))

        fixture.registry.apply([later, earlier])

        let adapters = fixture.registry.snapshot.debugAdapters
        #expect(adapters["rust"]?.adapter.id == "alpha")
        #expect(adapters["zig"]?.adapter.id == "alpha")
        #expect(adapters["java"] == nil)
    }

    /// The Debug button launches the open file, so an adapter that only
    /// attaches is never chosen for it, yet its language is still recognised
    /// as one the plugin has a debugger for and not as a competing owner.
    @Test
    func anAttachOnlyAdapterIsNotChosenToLaunchAFile() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package(Self.debugManifest(requests: ["attach"]))

        fixture.registry.apply([package])

        let snapshot = fixture.registry.snapshot
        #expect(snapshot.debugAdapters["rust"] == nil)
        #expect(snapshot.languageSupports.map(\.id) == ["rust"])
        #expect(snapshot.languageSupports.allSatisfy { $0.isDebugOnly })
    }

    @Test(arguments: [["process"], ["executable", "runTarget"], ["connection"]])
    func anAdapterWhoseSelectorSkipsFileTargetsIsNotChosenToLaunchAFile(_ targetKinds: [String]) throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let connectionOnly = targetKinds == ["connection"]
        var manifest = Self.debugManifest(requests: connectionOnly ? ["attach"] : ["launch"], targetKinds: targetKinds)
        if connectionOnly {
            // Connection selectors require an actual attach binding. Keep the
            // fixture valid while checking that it never owns a file launch.
            var adapters = try #require(manifest["debugAdapters"] as? [[String: Any]])
            adapters[0]["configurations"] = ["attach": ["targetBindings": ["connection": ["host": "hostName", "port": "port"]]]]
            manifest["debugAdapters"] = adapters
        }
        let package = try fixture.package(manifest)

        fixture.registry.apply([package])

        let snapshot = fixture.registry.snapshot
        #expect(snapshot.debugAdapters["rust"] == nil)
        #expect(snapshot.languageSupports.allSatisfy { $0.isDebugOnly })
    }

    @Test
    func anAdapterThatServesLaunchAndAttachIsStillChosenToLaunchAFile() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package(Self.debugManifest(requests: ["launch", "attach"]))

        fixture.registry.apply([package])

        #expect(fixture.registry.snapshot.debugAdapters["rust"]?.adapter.id == "lldb")
    }

    @Test
    func theCapabilitiesAManifestDisablesReachTheAdapterEntry() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package(Self.debugManifest(
            disabledCapabilities: ["supportsStepBack", "exceptionBreakpointFilters"]
        ))

        fixture.registry.apply([package])

        let adapter = fixture.registry.snapshot.debugAdapters["rust"]?.adapter
        #expect(Set(adapter?.disabledCapabilities ?? []) == ["supportsStepBack", "exceptionBreakpointFilters"])
    }

    @Test
    func anAdapterThatDisablesNothingReportsNoDisabledCapabilities() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }

        fixture.registry.apply([try fixture.package(Self.debugManifest())])

        #expect(fixture.registry.snapshot.debugAdapters["rust"]?.adapter.disabledCapabilities == [])
    }

    @Test
    func replacedRemovedAndDisabledPackagesAreWithdrawn() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.package(Self.debugManifest())
        let second = try fixture.package(Self.debugManifest(version: PluginVersion(major: 0, minor: 2, patch: 0)))

        fixture.registry.apply([first])
        #expect(fixture.withdrawn.isEmpty)

        fixture.registry.apply([second])
        #expect(fixture.withdrawn.map(\.manifest.version) == [first.manifest.version])

        fixture.isEnabled = false
        fixture.registry.refreshEnablement()
        #expect(fixture.withdrawn.map(\.manifest.version) == [first.manifest.version, second.manifest.version])

        fixture.isEnabled = true
        fixture.registry.refreshEnablement()
        fixture.withdrawn.removeAll()
        fixture.registry.apply([])
        #expect(fixture.withdrawn.map(\.manifest.version) == [second.manifest.version])
    }

    @Test
    func aPackageAboutToBeReplacedIsWithdrawnBeforeTheFilesChange() throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package(Self.debugManifest())
        fixture.registry.apply([package])

        fixture.registry.willReplacePackage(of: PluginID("dev.example.unknown"))
        #expect(fixture.withdrawn.isEmpty)
        fixture.registry.willReplacePackage(of: Self.pluginID)
        #expect(fixture.withdrawn == [package])
    }

    // MARK: - Scanning

    @Test
    func theScanReadsTheInstalledPackagesOffTheMainThread() async throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let source = try fixture.writeSource(Self.debugManifest(), name: "v1")
        let installed = try fixture.store.installPackage(from: source, origin: .localDevelopment)

        let arrived = try await fixture.awaitChange { fixture.registry.packagesDidChange() }
        #expect(arrived)
        // The scan resolves the temporary directory's symlink, so compare the
        // installation rather than the path.
        #expect(fixture.registry.snapshot.entries[Self.pluginID]?.package.installation == installed.installation)
        #expect(fixture.scanThreads.values == [false])

        try fixture.store.uninstall(Self.pluginID)
        let removed = try await fixture.awaitChange { fixture.registry.packagesDidChange() }
        #expect(removed)
        #expect(fixture.registry.snapshot.entries.isEmpty)
        #expect(fixture.withdrawn.map(\.installation) == [installed.installation])
    }

    @Test
    func aFailedScanKeepsTheLastRegistrations() async throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let source = try fixture.writeSource(Self.debugManifest(), name: "v1")
        _ = try fixture.store.installPackage(from: source, origin: .localDevelopment)
        _ = try await fixture.awaitChange { fixture.registry.packagesDidChange() }
        #expect(fixture.registry.snapshot.entries[Self.pluginID] != nil)
        let generation = fixture.registry.snapshot.generation

        // An unreadable plugin directory makes the scan throw instead of
        // reporting an empty store.
        let installedRoot = fixture.installedRoot
        try FileManager.default.removeItem(at: installedRoot)
        try Data().write(to: installedRoot)
        await fixture.registry.packagesDidChange().value

        #expect(fixture.registry.snapshot.entries[Self.pluginID] != nil)
        #expect(fixture.registry.snapshot.generation == generation)
    }

    @Test
    func anotherWindowsChangeMakesThisRegistryRescan() async throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let peer = fixture.makePeerRegistry()
        let source = try fixture.writeSource(Self.debugManifest(), name: "v1")
        _ = try fixture.store.installPackage(from: source, origin: .localDevelopment)

        // The peer announces a change; this registry never scanned on its own.
        let arrived = try await fixture.awaitChange { peer.packagesDidChange() }
        #expect(arrived)
        #expect(fixture.registry.snapshot.entries[Self.pluginID] != nil)
    }

    // MARK: - Manager flows

    @Test
    func installingALivePluginActivatesItAtOnce() async throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let source = try fixture.writeSource(Self.debugManifest(), name: "v1")

        let arrived = try await fixture.awaitChange { try manager.installPackage(at: source) }

        #expect(arrived)
        let entry = try #require(fixture.registry.snapshot.entries[Self.pluginID])
        #expect(entry.isEnabled)
        #expect(entry.package.installation.status == .installed)
        #expect(fixture.registry.snapshot.debugAdapters["rust"]?.plugin.manifest.id == Self.pluginID)
        let snapshot = try #require(manager.snapshots.first { $0.id == Self.pluginID })
        #expect(snapshot.installationStatus == .installed)
        #expect(!snapshot.requiresRestart)
        #expect(!snapshot.hasChangesPendingRestart)
        #expect(snapshot.isEnabled)
    }

    @Test
    func installingAnyOtherPluginStillWaitsForARestart() throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let source = try fixture.writeSource(
            DeclarativePluginTestSupport.manifestObject(
                id: "dev.example.language",
                version: PluginVersion(major: 1, minor: 0, patch: 0),
                signatureRequirement: .publisherPackage
            ),
            name: "language"
        )

        try manager.installPackage(at: source)

        let snapshot = try #require(manager.snapshots.first { $0.id == PluginID("dev.example.language") })
        #expect(snapshot.installationStatus == .updateStaged)
        #expect(snapshot.requiresRestart)
        #expect(snapshot.hasChangesPendingRestart)
        // Nothing was scheduled, so there is no scan left to wait for.
        #expect(fixture.registry.snapshot == LivePluginSnapshot())
    }

    @Test
    func updatingALivePluginReplacesItsRegistrationAndRollbackRestoresIt() async throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let first = PluginVersion(major: 0, minor: 1, patch: 0)
        let second = PluginVersion(major: 0, minor: 2, patch: 0)

        _ = try await fixture.awaitChange {
            try manager.installPackage(at: fixture.writeSource(Self.debugManifest(version: first), name: "v1"))
        }
        let generation = fixture.registry.snapshot.generation

        let updated = try await fixture.awaitChange {
            try manager.installPackage(at: fixture.writeSource(Self.debugManifest(version: second), name: "v2"))
        }
        #expect(updated)
        #expect(fixture.registry.snapshot.entries[Self.pluginID]?.package.manifest.version == second)
        #expect(fixture.registry.snapshot.generation > generation)
        #expect(fixture.withdrawn.contains { $0.manifest.version == first })
        #expect(try #require(manager.snapshots.first { $0.id == Self.pluginID }).requiresRestart == false)

        let rolledBack = try await fixture.awaitChange { try manager.rollback(Self.pluginID) }
        #expect(rolledBack)
        #expect(fixture.registry.snapshot.entries[Self.pluginID]?.package.manifest.version == first)
        #expect(fixture.withdrawn.contains { $0.manifest.version == second })
        let snapshot = try #require(manager.snapshots.first { $0.id == Self.pluginID })
        #expect(!snapshot.requiresRestart)
        #expect(snapshot.installationStatus == .installed)
    }

    @Test
    func disablingAndEnablingALivePluginTakesEffectWithoutAScan() async throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let source = try fixture.writeSource(Self.debugManifest(), name: "v1")
        _ = try await fixture.awaitChange { try manager.installPackage(at: source) }
        #expect(fixture.registry.snapshot.debugAdapters["rust"] != nil)

        try await manager.setEnabled(false, for: Self.pluginID)

        #expect(fixture.registry.snapshot.entries[Self.pluginID]?.isEnabled == false)
        #expect(fixture.registry.snapshot.debugAdapters.isEmpty)
        #expect(!(try #require(manager.snapshots.first { $0.id == Self.pluginID }).requiresRestart))

        try await manager.setEnabled(true, for: Self.pluginID)

        #expect(fixture.registry.snapshot.debugAdapters["rust"] != nil)
        #expect(!(try #require(manager.snapshots.first { $0.id == Self.pluginID }).requiresRestart))
    }

    @Test
    func uninstallingALivePluginRemovesItImmediately() async throws {
        let fixture = try LiveFixture(acceptance: .startupLoader)
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let source = try fixture.writeSource(Self.debugManifest(), name: "v1")
        _ = try await fixture.awaitChange { try manager.installPackage(at: source) }

        let removed = try await fixture.awaitChange { try await manager.uninstall(Self.pluginID) }

        #expect(removed)
        #expect(fixture.registry.snapshot.entries.isEmpty)
        #expect(fixture.withdrawn.contains { $0.manifest.id == Self.pluginID })
        // The package is gone now, not marked for removal at the next launch.
        #expect(try fixture.store.scanInstalledPlugins().packages.isEmpty)
        #expect(manager.snapshots.allSatisfy { $0.id != Self.pluginID })
    }

    // MARK: - Fixtures

    private static func debugManifest(
        id: String = pluginID.rawValue,
        version: PluginVersion = PluginVersion(major: 0, minor: 1, patch: 0),
        adapterID: String = "lldb",
        languageIDs: [String] = ["rust"],
        requests: [String] = ["launch"],
        targetKinds: [String] = ["file"],
        disabledCapabilities: [String] = []
    ) -> [String: Any] {
        var adapter: [String: Any] = [
            "id": adapterID,
            "displayName": "Example",
            "adapterID": "example-dap",
            "requests": requests,
            "selectors": [["targetKinds": targetKinds, "languageIDs": languageIDs]],
            "configurationTypes": [adapterID],
            "launch": [
                "process": ["launch": ["kind": "systemCommand", "commands": ["example-dap"]]],
                "transport": "stdio"
            ]
        ]
        if requests.contains("launch") {
            adapter["configurations"] = ["launch": ["arguments": ["stopOnEntry": false]]]
        }
        if !disabledCapabilities.isEmpty {
            adapter["capabilities"] = ["disabled": disabledCapabilities]
        }
        return [
            "schemaVersion": 2,
            "id": id,
            "displayName": "Example Debugger",
            "version": version.description,
            "pluginAPIVersion": 4,
            "requires": ["debugAdapters": 1, "languages": 1, "serverProcess": 1],
            "vendor": [
                "id": "dev.example",
                "displayName": "Example",
                "signatureRequirement": PluginSignatureRequirement.publisherPackage.rawValue
            ],
            "permissions": requests.contains("attach") ? ["debug.launch", "debug.attach"] : ["debug.launch"],
            "activationEvents": ["onDebug:\(adapterID)"],
            "languages": languageIDs.map {
                ["id": $0, "displayName": $0.capitalized, "fileExtensions": [$0]] as [String: Any]
            },
            "debugAdapters": [adapter]
        ]
    }
}

/// One window's plugin store, registry and manager over a temporary directory.
@MainActor
private final class LiveFixture {
    enum Acceptance {
        /// Adopt whatever qualifies, without the module-graph checks.
        case identity
        /// The startup loader's own checks, as production uses.
        case startupLoader
    }

    let root: URL
    let installedRoot: URL
    let store: MacPluginPackageStore
    let center = NotificationCenter()
    let scanThreads = ScanThreads()
    let configuration = MacModuleConfigurationStore(store: LiveActivationKeyValueStore())
    var isEnabled = true
    var withdrawn: [InstalledPluginPackage] = []
    private(set) var registry: MacLivePluginRegistry!
    private let loader: MacPluginStartupLoader
    private let acceptance: Acceptance

    init(acceptance: Acceptance = .identity) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-live-activation-\(UUID().uuidString)", isDirectory: true)
        installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        store = MacPluginPackageStore(
            rootURL: installedRoot,
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true)
        )
        loader = MacPluginStartupLoader(packageStore: store, validateUI: { _ in })
        self.acceptance = acceptance
        registry = makeRegistry(center: center, followsFixtureEnablement: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A second window over the same packages, sharing the notification center.
    func makePeerRegistry() -> MacLivePluginRegistry {
        makeRegistry(center: center, followsFixtureEnablement: true, recordsScans: false)
    }

    func makeManager() -> MacPluginManager {
        MacPluginManager(
            packageStore: store,
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: [], registeredPlugins: [], issues: []),
            allowsLocalDevelopmentPackages: true,
            beforePackageReplacement: { [registry] in registry?.willReplacePackage(of: $0) },
            livePlugins: registry
        )
    }

    func package(
        _ manifest: [String: Any],
        status: PluginInstallationStatus = .installed
    ) throws -> InstalledPluginPackage {
        let descriptor = try DeclarativePluginTestSupport.descriptor(manifest)
        return InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .marketplace,
                status: status
            ),
            packageURL: root.appendingPathComponent("unused", isDirectory: true)
        )
    }

    @discardableResult
    func writeSource(_ manifest: [String: Any], name: String) throws -> URL {
        try DeclarativePluginTestSupport.writePackage(
            at: root.appendingPathComponent("sources/\(name)", isDirectory: true),
            manifest: manifest
        )
    }

    /// Runs `trigger`, then waits for the registry to publish a change. A
    /// publication that lands while `trigger` runs is remembered, so the
    /// order of the two never matters. The deadline only bounds a failing run;
    /// a passing one returns on the event.
    func awaitChange(
        within deadline: DispatchTimeInterval = .seconds(8),
        after trigger: () async throws -> Void
    ) async throws -> Bool {
        let latch = ChangeLatch()
        let subscription = registry.changes.sink { latch.fire() }
        defer { subscription.cancel() }
        try await trigger()
        return await latch.wait(deadline: deadline)
    }

    private func makeRegistry(
        center: NotificationCenter,
        followsFixtureEnablement: Bool,
        recordsScans: Bool = true
    ) -> MacLivePluginRegistry {
        let scanStore = store.makeScanStoreFactory()
        let threads = scanThreads
        let loader = loader
        let acceptance = acceptance
        let configuration = configuration
        return MacLivePluginRegistry(
            initial: [],
            registeredManifests: [],
            makeScanStore: {
                if recordsScans { threads.record(isMainThread: Thread.isMainThread) }
                return scanStore()
            },
            accept: { packages, registered in
                switch acceptance {
                case .identity: MacPluginAcceptance(accepted: packages)
                case .startupLoader: loader.accept(packages, alongside: registered)
                }
            },
            isEnabled: { [weak self] package in
                guard let self else { return false }
                guard acceptance == .startupLoader else { return isEnabled }
                // The same decision the composition root makes.
                return isEnabled && package.manifest.modules.allSatisfy { declaration in
                    let id = declaration.manifest.id
                    return !configuration.isQuarantined(id)
                        && (configuration.enabledState(for: id) ?? (declaration.manifest.defaultState == .enabled))
                }
            },
            didWithdraw: { [weak self] in self?.withdrawn.append($0) },
            notificationCenter: center
        )
    }
}

/// Remembers whether a change was published and resumes one waiter when it
/// is. Both the publication and the deadline arrive on the main actor.
@MainActor
private final class ChangeLatch {
    private var fired = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func fire() {
        fired = true
        resume(true)
    }

    func wait(deadline: DispatchTimeInterval) async -> Bool {
        if fired { return true }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
                MainActor.assumeIsolated { self?.resume(false) }
            }
        }
    }

    private func resume(_ value: Bool) {
        guard let pending = waiter else { return }
        waiter = nil
        pending.resume(returning: value)
    }
}

/// Where the scan's store factory ran, recorded from the background thread.
private final class ScanThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(isMainThread)
    }
}

private final class LiveActivationKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
