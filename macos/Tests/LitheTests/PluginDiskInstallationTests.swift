import CryptoKit
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning
import Testing
@testable import Lithe

/// Exercises disk preparation and installation with real Rust review and release
/// trust checks. Fixtures stay under one owned root; no plugin program is run.
@MainActor
@Suite("Plugin disk installation")
struct PluginDiskInstallationTests {
    private static let pluginID = PluginID("io.example.disk-tools")
    private static let versionOne = PluginVersion(major: 1, minor: 0, patch: 0)
    private static let versionTwo = PluginVersion(major: 2, minor: 0, patch: 0)
    private static let launcher = "language-server/bin/intelephense"
    private static let publisherKeyID = "test-disk-publisher-v1"

    @MainActor
    private struct Fixture {
        let root: URL
        let store: MacPluginPackageStore
        let service: MacPluginMarketplaceService

        var temporaryDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }
        var installedDirectory: URL { root.appendingPathComponent("installed", isDirectory: true) }

        init(
            _ name: String,
            trustedPublisherKeys: [String: Curve25519.Signing.PublicKey] = [:],
            evaluator: any PluginMarketplaceEvaluating = PluginMarketplaceTestSupport.evaluator
        ) {
            let root = PluginMarketplaceTestSupport.temporaryRoot("disk-\(name)")
            self.root = root
            let transport = PluginMarketplaceTestSupport.LocalFileTransport(files: [:])
            let store = MacPluginPackageStore(
                rootURL: root.appendingPathComponent("installed", isDirectory: true),
                validator: DeclarativePluginTestSupport.operations,
                verifier: MacOfficialPluginSignatureVerifier(
                    trustedPublisherKeys: trustedPublisherKeys,
                    allowsLocalDevelopmentPackages: false,
                    hostBundleURL: root.appendingPathComponent("host/Lithe.app", isDirectory: true)
                )
            )
            self.store = store
            service = MacPluginMarketplaceService(
                evaluator: evaluator,
                packageStore: store,
                downloader: MacPluginPackageDownloader(
                    transport: transport,
                    temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
                ),
                transport: transport,
                applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
                cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
                bundledOfficialIndexURL: nil,
                platform: "darwin-arm64",
                diskImporter: MacPluginDiskPackageImporter(
                    temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
                ),
                allowsLocalDevelopmentPackages: false
            )
        }

        /// Reuses the contract fixture's packaged server, runtime dependency,
        /// run arguments and conditional test arguments, under a community ID.
        func writePackage(
            _ name: String,
            version: PluginVersion = PluginDiskInstallationTests.versionOne,
            id: PluginID = PluginDiskInstallationTests.pluginID,
            signatureRequirement: PluginSignatureRequirement = .unsigned
        ) throws -> URL {
            let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("shared/contracts/plugins/v1/fixtures/php-support.plugin.json"))
            var manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            manifest["id"] = id.rawValue
            manifest["displayName"] = "Disk Fixture"
            manifest["version"] = version.description
            manifest["vendor"] = [
                "id": "io.example",
                "displayName": "Example Developer",
                "signatureRequirement": signatureRequirement.rawValue,
            ]
            var servers = try #require(manifest["languageServers"] as? [[String: Any]])
            servers[0]["validationArguments"] = ["--version"]
            manifest["languageServers"] = servers
            return try DeclarativePluginTestSupport.writePackage(
                at: root.appendingPathComponent("sources/\(name)", isDirectory: true),
                manifest: manifest
            )
        }

        func sign(_ package: URL, key: Curve25519.Signing.PrivateKey) throws {
            let manifest = try store.inspectPackage(at: package).pluginManifest
            let document = try PluginPackageSignature.makeDocument(
                packageAt: package,
                pluginID: manifest.id.rawValue,
                pluginVersion: manifest.version.description,
                privateKey: key,
                keyID: PluginDiskInstallationTests.publisherKeyID
            )
            try PluginPackageSignature.write(document, to: package)
        }
    }

    /// Only fixed macOS tooling creates the archive, on a worker thread. Its
    /// watchdog and process-tree cleanup fit inside the test's 15-second budget.
    private static func zip(_ package: URL, to archive: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = MacProcessRunner().run(ProcessRequest(
                    executablePath: "/usr/bin/ditto",
                    arguments: ["-c", "-k", "--keepParent", package.path, archive.path],
                    timeoutMilliseconds: 5_000
                ))
                if result.succeeded {
                    continuation.resume(returning: archive)
                } else {
                    continuation.resume(throwing: CocoaError(
                        .fileWriteUnknown,
                        userInfo: [NSLocalizedDescriptionKey: result.output]
                    ))
                }
            }
        }
    }

    /// Synthetic repository metadata for Store transition tests. The actual
    /// content digest and complete approvals come from the real disk review.
    private static func marketplaceApproval(for prepared: PreparedDiskPluginPackage) -> PluginMarketplaceProvenance {
        PluginMarketplaceProvenance(
            sourceID: "source-fixture",
            sourceName: "Fixture Repository",
            repository: "https://github.com/example/disk-tools",
            archiveSHA256: String(repeating: "a", count: 64),
            contentDigest: prepared.provenance.contentDigest,
            approvedPrograms: prepared.provenance.approvedPrograms
        )
    }

    @Test(arguments: [false, true])
    func directoryAndZIPApprovalsInstallOnlyTheReviewedSnapshot(zipped: Bool) async throws {
        let fixture = Fixture(zipped ? "zip" : "directory")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try fixture.writePackage("selected-package")
        let selected: URL
        if zipped {
            selected = try await Self.zip(package, to: fixture.root.appendingPathComponent("selected.zip"))
        } else {
            selected = package
        }
        let expectedDigest = try PluginPackageSignature.contentDigest(packageAt: package)
        let expectedArchiveDigest = zipped ? try MacPluginPackageDownloader.sha256(of: selected) : nil
        let prepared = try await fixture.service.prepareDiskInstall(at: selected)
        defer { fixture.service.discard(prepared) }

        // Compare every Core field, including executable objects, validation
        // probes and conditional templates; a presentation-only projection loses approval semantics.
        let expectedPrograms = try [
            #"{"kind":"packagedLanguageServer","languageID":"php","path":"language-server/bin/intelephense","arguments":["--stdio"],"validationArguments":["--version"]}"#,
            #"{"kind":"run","languageID":"php","executable":{"command":"php"},"arguments":["${file}","${userArguments}"]}"#,
            #"{"kind":"runtime","tool":"node"}"#,
            #"{"kind":"test","languageID":"php","executable":{"command":"php"},"workspaceArguments":["vendor/bin/phpunit"],"fileArguments":["vendor/bin/phpunit","${file}"],"testCaseArguments":["vendor/bin/phpunit","--filter","\\b${testName:regex}\\b",{"value":"${file}","when":"fileSelected"}]}"#,
        ].map { try PluginProgram(canonicalJSON: $0) }
        #expect(prepared.pluginID == Self.pluginID)
        #expect(prepared.displayName == "Disk Fixture")
        #expect(prepared.author == "Example Developer")
        #expect(prepared.origin == .community)
        #expect(prepared.review.pluginID == Self.pluginID.rawValue)
        #expect(prepared.review.version == "1.0.0")
        #expect(prepared.review.permissions == ["languageServer.launch", "process.run", "process.test"])
        #expect(prepared.review.programs == expectedPrograms)
        #expect(prepared.review.newPrograms == expectedPrograms)
        #expect(prepared.provenance.fileName == selected.lastPathComponent)
        #expect(prepared.provenance.archiveSHA256 == expectedArchiveDigest)
        #expect(prepared.provenance.contentDigest == expectedDigest)
        #expect(prepared.provenance.approvedPrograms == (try expectedPrograms.map { try $0.canonicalJSON() }))
        #expect(prepared.packageURL.resolvingSymlinksInPath() != package.resolvingSymlinksInPath())
        #expect(prepared.temporaryDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
            == fixture.temporaryDirectory.resolvingSymlinksInPath())
        #expect(try fixture.store.scanInstalledPlugins().packages.isEmpty)

        if zipped {
            try Data("replaced after approval".utf8).write(to: selected)
        } else {
            try Data("changed after approval".utf8).write(to: selected.appendingPathComponent(Self.launcher))
        }
        #expect(try PluginPackageSignature.contentDigest(packageAt: prepared.packageURL) == expectedDigest)
        let installed = try fixture.store.installPackage(
            from: prepared.packageURL, origin: prepared.origin, disk: prepared.provenance
        )
        let scan = try fixture.store.scanInstalledPlugins()
        #expect(scan.issues.isEmpty)
        #expect(scan.packages.count == 1)
        let scanned = try #require(scan.packages.first)
        #expect(scanned.descriptor == installed.descriptor)
        #expect(scanned.installation == installed.installation)
        #expect(scanned.packageURL.resolvingSymlinksInPath() == installed.packageURL.resolvingSymlinksInPath())
        #expect(installed.installation.marketplace == nil)
        #expect(installed.installation.disk == prepared.provenance)
        #expect(try PluginPackageSignature.contentDigest(packageAt: installed.packageURL) == expectedDigest)
        let storedDisk = try #require(scan.packages.first?.installation.disk)
        let restoredPrograms = try storedDisk.approvedPrograms.map { try PluginProgram(canonicalJSON: $0) }
        #expect(restoredPrograms == expectedPrograms)
        let unchanged = try PluginMarketplaceTestSupport.evaluator.installReview(
            manifest: Data(contentsOf: installed.packageURL.appendingPathComponent("plugin.json")),
            expectedID: Self.pluginID.rawValue, expectedVersion: "1.0.0", approvedPrograms: restoredPrograms
        )
        #expect(unchanged.newPrograms.isEmpty)

        fixture.service.discard(prepared)
        #expect(!FileManager.default.fileExists(atPath: prepared.temporaryDirectory.path))
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path).isEmpty)
    }

    /// Pause the synchronous Rust-review boundary on its native worker, cancel
    /// from the UI actor, then release it. Cleanup must wait for the reader.
    @Test
    func cancellingBackgroundReviewKeepsUIResponsiveAndCleansAfterWorkerFinishes() async throws {
        let evaluator = GatedDiskReviewEvaluator()
        let fixture = Fixture("cancel-background-review", evaluator: evaluator)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try fixture.writePackage("selected")
        let task = Task { try await fixture.service.prepareDiskInstall(at: package) }
        defer {
            task.cancel()
            evaluator.release.open()
        }
        let entered = await evaluator.entered.waitUntilOpen()
        task.cancel()
        let snapshotDirectories = (try? FileManager.default.contentsOfDirectory(
            at: fixture.temporaryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        evaluator.release.open()
        let result = await task.result
        #expect(entered)
        #expect(snapshotDirectories.count == 1)
        switch result {
        case .success(let prepared):
            fixture.service.discard(prepared)
            Issue.record("A cancelled disk review must not return an approval candidate")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path).isEmpty)
        #expect(try fixture.store.scanInstalledPlugins().packages.isEmpty)
    }

    /// A confirmed first installation is enabled at the next launch, so its
    /// tool windows appear; an update keeps the user's later choice.
    @Test
    func confirmedFirstInstallationIsEnabledAndUpdateKeepsTheUsersChoice() async throws {
        let fixture = Fixture("enable-first-install")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = MacModuleConfigurationStore(store: DiskInstallationKeyValueStore())
        let manager = MacPluginManager(
            packageStore: fixture.store,
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: [], registeredPlugins: [], issues: []),
            allowsLocalDevelopmentPackages: false
        )
        let first = try await fixture.service.prepareDiskInstall(at: try fixture.writePackage("first"))
        defer { fixture.service.discard(first) }

        try manager.installDiskPackage(at: first.packageURL, provenance: first.provenance)

        let snapshot = try #require(manager.snapshots.first { $0.id == Self.pluginID })
        #expect(!snapshot.manifest.modules.isEmpty)
        #expect(snapshot.manifest.modules.allSatisfy { $0.manifest.defaultState == .disabled })
        #expect(snapshot.manifest.modules.allSatisfy { configuration.enabledState(for: $0.manifest.id) == true })
        #expect(snapshot.isEnabled)
        #expect(snapshot.requiresRestart)

        try await manager.setEnabled(false, for: Self.pluginID)
        let update = try await fixture.service.prepareDiskInstall(
            at: try fixture.writePackage("update", version: Self.versionTwo)
        )
        defer { fixture.service.discard(update) }
        try manager.installDiskPackage(at: update.packageURL, provenance: update.provenance)

        #expect(snapshot.manifest.modules.allSatisfy { configuration.enabledState(for: $0.manifest.id) == false })
        #expect(manager.snapshots.first { $0.id == Self.pluginID }?.isEnabled == false)
    }

    /// Rejected packages must not persist enablement into another plugin's
    /// language-derived module IDs, including when the owner has no preference.
    @Test(arguments: [false, true], [nil, false, true] as [Bool?])
    func firstInstallationDoesNotChangeAnotherPluginsModulePreferences(
        bundledOwner: Bool, enabledPreference: Bool?
    ) async throws {
        let fixture = Fixture("module-owner-collision")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = MacModuleConfigurationStore(store: DiskInstallationKeyValueStore())
        let owner: PluginManifest
        if bundledOwner {
            owner = try #require(BundledLanguagePluginCatalog.manifests.first {
                $0.id == PluginID("dev.lithe.plugin.python-support")
            })
        } else {
            let prepared = try await fixture.service.prepareDiskInstall(at: fixture.writePackage(
                "existing", id: PluginID("io.example.a-existing-tools")
            ))
            defer { fixture.service.discard(prepared) }
            owner = try fixture.store.installPackage(
                from: prepared.packageURL, origin: .community, disk: prepared.provenance
            ).manifest
        }
        #expect(owner.modules.allSatisfy { $0.manifest.defaultState == .disabled })
        for declaration in owner.modules {
            if let enabledPreference {
                configuration.setEnabledState(enabledPreference, for: declaration.manifest.id)
            }
        }
        let startup = MacPluginStartupLoader(packageStore: fixture.store, validateUI: { _ in })
            .load(recoveryStore: configuration)
        let manager = MacPluginManager(
            packageStore: fixture.store,
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration, settings: InMemoryPluginSettings(), launchMode: .normal,
            startup: startup, allowsLocalDevelopmentPackages: false
        )
        let source = try fixture.writePackage("conflicting")
        if bundledOwner {
            let manifestURL = source.appendingPathComponent("plugin.json")
            let json = try String(contentsOf: manifestURL, encoding: .utf8)
                .replacingOccurrences(of: "php", with: "python")
            try Data(json.utf8).write(to: manifestURL)
        }
        let candidate = try await fixture.service.prepareDiskInstall(at: source)
        defer { fixture.service.discard(candidate) }
        try manager.installDiskPackage(at: candidate.packageURL, provenance: candidate.provenance)
        #expect(owner.modules.allSatisfy {
            configuration.enabledState(for: $0.manifest.id) == enabledPreference
        })

        let restarted = MacPluginStartupLoader(packageStore: fixture.store, validateUI: { _ in })
            .load(recoveryStore: configuration)
        #expect(!restarted.registeredPlugins.contains { $0.manifest.id == Self.pluginID })
        #expect(restarted.issues.contains { $0.pluginID == Self.pluginID })
        if !bundledOwner {
            #expect(restarted.registeredPlugins.contains { $0.manifest.id == owner.id })
        }
        let runtime = ModuleRuntime(configurationStore: configuration, recoveryStore: configuration)
        for declaration in owner.modules {
            try runtime.register(ModuleFactory(manifest: declaration.manifest) {
                throw CocoaError(.featureUnsupported)
            })
        }
        #expect(runtime.snapshots().allSatisfy {
            $0.state == (enabledPreference == true ? .inactive : .disabled)
        })
        #expect(owner.modules.allSatisfy {
            configuration.enabledState(for: $0.manifest.id) == enabledPreference
        })
    }

    /// Cover disk review -> manager -> Store -> process-wide lifecycle without
    /// view notifications, including pages retained by hidden tool windows.
    @Test(arguments: [false, true])
    func diskReplacementClosesEveryProjectPageBeforeMutation(sameVersion: Bool) async throws {
        let fixture = Fixture(sameVersion ? "page-replacement" : "page-upgrade")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        func webPackage(_ name: String, version: PluginVersion, content: String) throws -> URL {
            let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("shared/contracts/plugins/v1/fixtures/web-panel.plugin.json"))
            let json = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "dev.lithe.fixture.web-panel", with: Self.pluginID.rawValue)
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            manifest["version"] = version.description
            manifest["vendor"] = ["id": "io.example", "displayName": "Example", "signatureRequirement": "none"]
            let package = try DeclarativePluginTestSupport.writePackage(
                at: fixture.root.appendingPathComponent(name), manifest: manifest
            )
            try FileManager.default.createDirectory(at: package.appendingPathComponent("ui"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: package.appendingPathComponent("icons"), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: package.appendingPathComponent("ui/index.html"))
            try Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"/>"#.utf8)
                .write(to: package.appendingPathComponent("icons/panel.svg"))
            return package
        }
        let original = try await fixture.service.prepareDiskInstall(
            at: webPackage("original", version: Self.versionOne, content: "<p>original</p>")
        )
        defer { fixture.service.discard(original) }
        let installed = try fixture.store.installPackage(
            from: original.packageURL, origin: .community, disk: original.provenance
        )
        let entry = installed.packageURL.appendingPathComponent("ui/index.html")
        let record = fixture.installedDirectory.appendingPathComponent("\(Self.pluginID)/installation.json")
        let originalBytes = try Data(contentsOf: entry)
        let originalRecord = try Data(contentsOf: record)
        let window = PluginWebWindow(
            pluginID: Self.pluginID.rawValue, pluginName: "Fixture", windowID: "\(Self.pluginID).window",
            entry: "ui/index.html", packageURL: installed.packageURL, buildSystemIDs: [], isInspectable: false
        )
        let lifecycle = PluginWebPageLifecycle()
        var prompts = 0
        let projects = (0..<2).map { _ in
            PluginWebPages(windows: [window]) { _ in prompts += 1; return true }
        }
        defer { projects.forEach { $0.closeAll() } }
        let pages = try projects.map { registry in
            lifecycle.register(registry)
            return try #require(registry.page(for: window.windowID) { _ in DiskInstallationPage() })
        }
        let consents = (0..<2).map { index in
            PluginWebProcessConsent(
                pluginID: Self.pluginID.rawValue, pluginName: "Fixture",
                workspaceURL: fixture.root.appendingPathComponent("workspace-\(index)"), action: "Build", userArguments: []
            )
        }
        for (registry, consent) in Swift.zip(projects, consents) {
            #expect(await registry.confirmProcessStart(consent))
        }
        #expect(prompts == 2)
        let configuration = MacModuleConfigurationStore(store: DiskInstallationKeyValueStore())
        var mutations: [PluginID] = []
        let manager = MacPluginManager(
            packageStore: fixture.store,
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration, settings: InMemoryPluginSettings(), launchMode: .normal,
            startup: MacPluginStartupResult(installedPlugins: [installed], registeredPlugins: [installed], issues: []),
            allowsLocalDevelopmentPackages: false,
            beforePackageReplacement: { id in
                // Invalidation must precede replacing resources or the installation record.
                #expect((try? Data(contentsOf: entry)) == originalBytes)
                #expect((try? Data(contentsOf: record)) == originalRecord)
                mutations.append(id)
                lifecycle.packageWillChange(id.rawValue)
            }
        )
        let replacement = try await fixture.service.prepareDiskInstall(at: webPackage(
            "replacement", version: sameVersion ? Self.versionOne : Self.versionTwo, content: "<p>replacement</p>"
        ))
        defer { fixture.service.discard(replacement) }
        let replacementEntry = replacement.packageURL.appendingPathComponent("ui/index.html")
        let reviewedBytes = try Data(contentsOf: replacementEntry)
        try Data("unapproved".utf8).write(to: replacementEntry)
        #expect(throws: PluginPackageStoreError.communityContentChanged(Self.pluginID)) {
            try manager.installDiskPackage(at: replacement.packageURL, provenance: replacement.provenance)
        }
        #expect(mutations.isEmpty)
        #expect(pages.allSatisfy { !$0.isClosed })
        try reviewedBytes.write(to: replacementEntry)

        try manager.installDiskPackage(at: replacement.packageURL, provenance: replacement.provenance)
        #expect(mutations == [Self.pluginID])
        #expect(pages.allSatisfy { $0.isClosed })
        #expect(manager.snapshots.first { $0.id == Self.pluginID }?.requiresRestart == true)
        let later = PluginWebPages(windows: [window])
        defer { later.closeAll() }
        lifecycle.register(later)
        lifecycle.disable(Self.pluginID.rawValue)
        lifecycle.enable(Self.pluginID.rawValue)
        for registry in projects + [later] {
            #expect(registry.openWindowIDs.isEmpty)
            #expect(registry.page(for: window.windowID) { _ in DiskInstallationPage() } == nil)
        }
        for (registry, consent) in Swift.zip(projects, consents) {
            #expect(await registry.confirmProcessStart(consent) == false)
        }
        #expect(prompts == 2)
    }

    @Test(arguments: [false, true])
    func changedSnapshotCannotReplaceOrDamageAnInstalledVersion(sameVersion: Bool) async throws {
        let fixture = Fixture(sameVersion ? "reject-replacement" : "reject-update")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try fixture.writePackage("original")
        let first = try await fixture.service.prepareDiskInstall(at: firstSource)
        defer { fixture.service.discard(first) }
        let installed = try fixture.store.installPackage(
            from: first.packageURL, origin: .community, disk: first.provenance
        )
        let recordURL = fixture.installedDirectory.appendingPathComponent("\(Self.pluginID)/installation.json")
        let originalRecord = try Data(contentsOf: recordURL)
        let originalDigest = try PluginPackageSignature.contentDigest(packageAt: installed.packageURL)
        let replacement = try fixture.writePackage(
            "replacement", version: sameVersion ? Self.versionOne : Self.versionTwo
        )
        let prepared = try await fixture.service.prepareDiskInstall(at: replacement)
        defer { fixture.service.discard(prepared) }
        try Data("changed after confirmation".utf8).write(to: prepared.packageURL.appendingPathComponent(Self.launcher))

        #expect(throws: PluginPackageStoreError.communityContentChanged(Self.pluginID)) {
            try fixture.store.installPackage(
                from: prepared.packageURL, replaceExisting: true, origin: .community, disk: prepared.provenance
            )
        }
        let scan = try fixture.store.scanInstalledPlugins()
        #expect(scan.issues.isEmpty)
        #expect(scan.packages.count == 1)
        let scanned = try #require(scan.packages.first)
        #expect(scanned.descriptor == installed.descriptor)
        #expect(scanned.installation == installed.installation)
        #expect(scanned.packageURL.resolvingSymlinksInPath() == installed.packageURL.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: recordURL) == originalRecord)
        #expect(try PluginPackageSignature.contentDigest(packageAt: installed.packageURL) == originalDigest)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.installedDirectory.appendingPathComponent("\(Self.pluginID)/versions").path
        ) == ["1.0.0"])
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.installedDirectory.appendingPathComponent(".staging").path
        ).isEmpty)
    }

    @Test
    func installedDiskPackageWithAnAddedHiddenFileIsNotLoaded() async throws {
        let fixture = Fixture("rescan")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try fixture.writePackage("selected")
        let prepared = try await fixture.service.prepareDiskInstall(at: source)
        defer { fixture.service.discard(prepared) }
        let installed = try fixture.store.installPackage(
            from: prepared.packageURL, origin: .community, disk: prepared.provenance
        )
        try Data("unapproved content".utf8).write(to: installed.packageURL.appendingPathComponent(".unapproved"))

        let scan = try fixture.store.scanInstalledPlugins()
        #expect(scan.packages.isEmpty)
        #expect(scan.issues == [PluginPackageScanIssue(
            pluginID: Self.pluginID,
            message: PluginPackageStoreError.communityContentChanged(Self.pluginID).localizedDescription
        )])
    }

    @Test
    func communityInstallationRequiresExactlyOneApprovalSource() async throws {
        let fixture = Fixture("exclusive-source")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try fixture.writePackage("selected")
        let prepared = try await fixture.service.prepareDiskInstall(at: source)
        defer { fixture.service.discard(prepared) }
        let marketplace = Self.marketplaceApproval(for: prepared)

        _ = try fixture.store.verifyCandidatePackage(
            at: prepared.packageURL, origin: .community, marketplace: nil, disk: prepared.provenance
        )
        _ = try fixture.store.verifyCandidatePackage(
            at: prepared.packageURL, origin: .community, marketplace: marketplace
        )
        #expect(throws: PluginPackageStoreError.communityContentChanged(Self.pluginID)) {
            try fixture.store.installPackage(from: prepared.packageURL, origin: .community)
        }
        #expect(throws: PluginPackageStoreError.communityContentChanged(Self.pluginID)) {
            try fixture.store.installPackage(
                from: prepared.packageURL, origin: .community, marketplace: marketplace, disk: prepared.provenance
            )
        }
        #expect(try fixture.store.scanInstalledPlugins().packages.isEmpty)
    }

    @Test(arguments: [false, true])
    func replacingAndRollingBackVersionsPreservesTheirOwnApprovalSource(diskFirst: Bool) async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let fixture = Fixture("source-history", trustedPublisherKeys: [Self.publisherKeyID: key.publicKey])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try fixture.writePackage(
            "first", signatureRequirement: diskFirst ? .unsigned : .publisherPackage
        )
        if !diskFirst { try fixture.sign(firstSource, key: key) }
        let first = try await fixture.service.prepareDiskInstall(at: firstSource)
        defer { fixture.service.discard(first) }
        let firstDisk = diskFirst ? first.provenance : nil
        let firstMarketplace = diskFirst ? nil : Self.marketplaceApproval(for: first)
        let firstOrigin: PluginInstallationOrigin = diskFirst ? .community : .marketplace
        #expect(first.origin == firstOrigin)
        _ = try fixture.store.installPackage(
            from: first.packageURL, origin: firstOrigin, marketplace: firstMarketplace, disk: firstDisk
        )

        let secondSource = try fixture.writePackage(
            "second", version: Self.versionTwo, signatureRequirement: diskFirst ? .publisherPackage : .unsigned
        )
        if diskFirst { try fixture.sign(secondSource, key: key) }
        let second = try await fixture.service.prepareDiskInstall(at: secondSource)
        defer { fixture.service.discard(second) }
        let secondDisk = diskFirst ? nil : second.provenance
        let secondMarketplace = diskFirst ? Self.marketplaceApproval(for: second) : nil
        let secondOrigin: PluginInstallationOrigin = diskFirst ? .marketplace : .community
        #expect(second.origin == secondOrigin)
        let updated = try fixture.store.installPackage(
            from: second.packageURL, origin: secondOrigin, marketplace: secondMarketplace, disk: secondDisk
        )
        #expect(updated.installation == PluginInstallationRecord(
            pluginID: Self.pluginID, activeVersion: Self.versionTwo, previousVersion: Self.versionOne,
            origin: secondOrigin, previousOrigin: firstOrigin,
            marketplace: secondMarketplace, previousMarketplace: firstMarketplace,
            disk: secondDisk, previousDisk: firstDisk
        ))

        let restoredUpdate = try fixture.store.rollback(Self.pluginID)
        #expect(restoredUpdate.installation == PluginInstallationRecord(
            pluginID: Self.pluginID, activeVersion: Self.versionOne, previousVersion: Self.versionTwo,
            origin: firstOrigin, previousOrigin: secondOrigin,
            marketplace: firstMarketplace, previousMarketplace: secondMarketplace,
            disk: firstDisk, previousDisk: secondDisk
        ))
        #expect(try fixture.store.rollback(Self.pluginID).installation == updated.installation)

        // Reinstall the active version from the other source with new bytes.
        // Its old approval must not overwrite the real previous version's.
        let replacementSource = try fixture.writePackage(
            "replacement", version: Self.versionTwo, signatureRequirement: diskFirst ? .unsigned : .publisherPackage
        )
        try Data("rebuilt version two".utf8).write(to: replacementSource.appendingPathComponent("build.txt"))
        if !diskFirst { try fixture.sign(replacementSource, key: key) }
        let replacement = try await fixture.service.prepareDiskInstall(at: replacementSource)
        defer { fixture.service.discard(replacement) }
        #expect(replacement.provenance.contentDigest != second.provenance.contentDigest)
        let replacementDisk = diskFirst ? replacement.provenance : nil
        let replacementMarketplace = diskFirst ? nil : Self.marketplaceApproval(for: replacement)
        let replacementOrigin = firstOrigin
        #expect(replacement.origin == replacementOrigin)
        let reinstalled = try fixture.store.installPackage(
            from: replacement.packageURL, replaceExisting: true, origin: replacementOrigin,
            marketplace: replacementMarketplace, disk: replacementDisk
        )
        let expectedReplacement = PluginInstallationRecord(
            pluginID: Self.pluginID, activeVersion: Self.versionTwo, previousVersion: Self.versionOne,
            origin: replacementOrigin, previousOrigin: firstOrigin,
            marketplace: replacementMarketplace, previousMarketplace: firstMarketplace,
            disk: replacementDisk, previousDisk: firstDisk
        )
        #expect(reinstalled.installation == expectedReplacement)
        #expect(try fixture.store.installedPlugins().first?.installation == expectedReplacement)
        #expect(expectedReplacement.with(status: .updateStaged) == PluginInstallationRecord(
            pluginID: Self.pluginID, activeVersion: Self.versionTwo, previousVersion: Self.versionOne,
            origin: replacementOrigin, previousOrigin: firstOrigin, status: .updateStaged,
            marketplace: replacementMarketplace, previousMarketplace: firstMarketplace,
            disk: replacementDisk, previousDisk: firstDisk
        ))

        let restored = try fixture.store.rollback(Self.pluginID)
        #expect(restored.installation == PluginInstallationRecord(
            pluginID: Self.pluginID, activeVersion: Self.versionOne, previousVersion: Self.versionTwo,
            origin: firstOrigin, previousOrigin: replacementOrigin,
            marketplace: firstMarketplace, previousMarketplace: replacementMarketplace,
            disk: firstDisk, previousDisk: replacementDisk
        ))
        let reapplied = try fixture.store.rollback(Self.pluginID)
        #expect(reapplied.installation == expectedReplacement)
        let scan = try fixture.store.scanInstalledPlugins()
        #expect(scan.issues.isEmpty)
        #expect(scan.packages.count == 1)
        let scanned = try #require(scan.packages.first)
        #expect(scanned.descriptor == reapplied.descriptor)
        #expect(scanned.installation == reapplied.installation)
        #expect(scanned.packageURL.resolvingSymlinksInPath() == reapplied.packageURL.resolvingSymlinksInPath())
    }

    @Test
    func legacyInstallationRecordsWithoutDiskFieldsStillDecode() throws {
        // Frozen pre-disk JSON, rather than a record encoded by the new model.
        let data = Data(#"""
        {
          "pluginID": "io.example.disk-tools",
          "activeVersion": "2.0.0",
          "previousVersion": "1.0.0",
          "origin": "community",
          "previousOrigin": "marketplace",
          "status": "installed",
          "marketplace": {
            "sourceID": "legacy-source",
            "sourceName": "Legacy Repository",
            "repository": "https://github.com/example/disk-tools",
            "archiveSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "contentDigest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "approvedPrograms": []
          }
        }
        """#.utf8)
        let record = try JSONDecoder().decode(PluginInstallationRecord.self, from: data)
        #expect(record.pluginID == Self.pluginID)
        #expect(record.activeVersion == Self.versionTwo)
        #expect(record.previousVersion == Self.versionOne)
        #expect(record.origin == .community)
        #expect(record.previousOrigin == .marketplace)
        #expect(record.marketplace?.sourceID == "legacy-source")
        #expect(record.previousMarketplace == nil)
        #expect(record.disk == nil)
        #expect(record.previousDisk == nil)
        #expect(try JSONDecoder().decode(PluginInstallationRecord.self, from: JSONEncoder().encode(record)) == record)
    }

    @Test
    func releaseDiskPreparationDoesNotRelaxSignatureOrNamespaceRequirements() async throws {
        let fixture = Fixture("release-policy")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let publisher = try fixture.writePackage("publisher", signatureRequirement: .publisherPackage)
        await #expect(throws: PluginPackageStoreError.missingPackageSignature) {
            _ = try await fixture.service.prepareDiskInstall(at: publisher)
        }
        let sameTeam = try fixture.writePackage("same-team", signatureRequirement: .sameTeamAsHost)
        await #expect(throws: PluginPackageStoreError.hostSealRequired(Self.pluginID)) {
            _ = try await fixture.service.prepareDiskInstall(at: sameTeam)
        }
        let reservedID = PluginID("dev.lithe.fixture.disk-tools")
        let reserved = try fixture.writePackage("reserved-namespace", id: reservedID)
        do {
            _ = try await fixture.service.prepareDiskInstall(at: reserved)
            Issue.record("A disk selection must not grant an unsigned package the official namespace.")
        } catch PluginPackageStoreError.declarationRejected(let pluginID, let rejection) {
            #expect(pluginID == reservedID)
            #expect(rejection.code == "plugin.manifest.invalid")
            #expect(rejection.field == "vendor.signatureRequirement")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path).isEmpty)
        #expect(try fixture.store.scanInstalledPlugins().packages.isEmpty)
    }

    @Test(arguments: [PluginSignatureRequirement.unsigned, .publisherPackage])
    func presentSignaturesCannotBeDowngradedToDiskApproval(_ requirement: PluginSignatureRequirement) async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let fixture = Fixture("present-signature", trustedPublisherKeys: [Self.publisherKeyID: key.publicKey])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try fixture.writePackage("signed", signatureRequirement: requirement)
        try fixture.sign(source, key: key)
        let prepared = try await fixture.service.prepareDiskInstall(at: source)
        defer { fixture.service.discard(prepared) }
        let expectedOrigin: PluginInstallationOrigin = requirement == .unsigned ? .community : .marketplace
        #expect(prepared.origin == expectedOrigin)
        let disk = requirement == .unsigned ? prepared.provenance : nil
        let installed = try fixture.store.installPackage(
            from: prepared.packageURL, origin: expectedOrigin, disk: disk
        )
        #expect(installed.installation.disk == disk)
        #expect(installed.installation.marketplace == nil)

        let invalidSignature = Data("not a signature document".utf8)
        try invalidSignature.write(to: source.appendingPathComponent(PluginPackageSignature.signatureFileName))
        let expectedError = PluginPackageStoreError.invalidPackageSignature("The signature document could not be decoded.")
        await #expect(throws: expectedError) {
            _ = try await fixture.service.prepareDiskInstall(at: source)
        }
        // The failed preparation cleans only its own import, keeping the
        // already-approved snapshot available to the user's confirmation.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryDirectory.path)
            == [prepared.temporaryDirectory.lastPathComponent])

        try invalidSignature.write(to: prepared.packageURL.appendingPathComponent(PluginPackageSignature.signatureFileName))
        // Signature documents are deliberately excluded from contentDigest.
        // The verifier must still reject one changed after approval.
        #expect(try PluginPackageSignature.contentDigest(packageAt: prepared.packageURL) == prepared.provenance.contentDigest)
        #expect(throws: expectedError) {
            try fixture.store.installPackage(
                from: prepared.packageURL, replaceExisting: true, origin: expectedOrigin, disk: disk
            )
        }
        let scan = try fixture.store.scanInstalledPlugins()
        #expect(scan.issues.isEmpty)
        #expect(scan.packages.count == 1)
        let scanned = try #require(scan.packages.first)
        #expect(scanned.descriptor == installed.descriptor)
        #expect(scanned.installation == installed.installation)
        #expect(scanned.packageURL.resolvingSymlinksInPath() == installed.packageURL.resolvingSymlinksInPath())
    }
}

/// The only synchronous wait runs on the service's native review worker. Its
/// local deadline also releases a regressed MainActor implementation to fail.
private final class GatedDiskReviewEvaluator: PluginMarketplaceEvaluating {
    let entered = TestGate()
    let release = TestGate()

    func validateIndex(
        _ index: Data, sourceKind: PluginMarketplaceSourceKind, platform: String
    ) throws -> PluginMarketplaceIndex {
        try PluginMarketplaceTestSupport.evaluator.validateIndex(index, sourceKind: sourceKind, platform: platform)
    }

    func resolveSource(_ input: String) throws -> PluginMarketplaceSourceResolution {
        try PluginMarketplaceTestSupport.evaluator.resolveSource(input)
    }

    func installReview(
        manifest: Data, expectedID: String?, expectedVersion: String?, approvedPrograms: [PluginProgram]?
    ) throws -> PluginInstallReview {
        guard !Thread.isMainThread else { throw ReviewError.usedMainThread }
        entered.open()
        guard release.waitSynchronously(timeout: 2) else { throw ReviewError.workerDeadline }
        return try PluginMarketplaceTestSupport.evaluator.installReview(
            manifest: manifest, expectedID: expectedID,
            expectedVersion: expectedVersion, approvedPrograms: approvedPrograms
        )
    }

    private enum ReviewError: Error {
        case usedMainThread
        case workerDeadline
    }
}

@MainActor
private final class DiskInstallationPage: PluginWebPageHandle {
    private(set) var isClosed = false
    func close() { isClosed = true }
}

private final class DiskInstallationKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
