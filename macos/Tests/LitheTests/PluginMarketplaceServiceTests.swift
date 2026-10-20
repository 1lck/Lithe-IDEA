import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

/// End-to-end marketplace flow with real Rust Core validation: index refresh,
/// archive checksum, trust per source, install review, and the integrity of
/// an installed community package.
@MainActor
@Suite("Plugin marketplace service")
struct PluginMarketplaceServiceTests {
    private static let communityRepository = "https://github.com/example/lithe-zig"
    private static let communityArchive = "https://github.com/example/lithe-zig/releases/download/v1.0.0/zig.zip"
    private static let communityIndex = "https://raw.githubusercontent.com/example/lithe-zig/HEAD/lithe-plugin-index.json"

    private struct Fixture {
        let root: URL
        let service: MacPluginMarketplaceService
        let store: MacPluginPackageStore
        let source: PluginMarketplaceSource
    }

    /// Builds a community package, its archive, and an index listing it.
    private func makeFixture(
        _ name: String,
        signatureRequirement: PluginSignatureRequirement = .unsigned,
        sourceKind: PluginMarketplaceSourceKind = .thirdParty,
        indexChecksum: String? = nil
    ) throws -> Fixture {
        let root = PluginMarketplaceTestSupport.temporaryRoot(name)
        let package = try DeclarativePluginTestSupport.writePackage(
            at: root.appendingPathComponent("build/io.example.zig-support", isDirectory: true),
            manifest: DeclarativePluginTestSupport.manifestObject(
                id: "io.example.zig-support",
                version: PluginVersion(major: 1, minor: 0, patch: 0),
                signatureRequirement: signatureRequirement,
                languageID: "zig",
                packagedLauncher: "bin/zls"
            )
        )
        let archive = try PluginMarketplaceTestSupport.zip(package, to: root.appendingPathComponent("zig.zip"))
        let index = root.appendingPathComponent("index.json")
        try PluginMarketplaceTestSupport.indexData([
            PluginMarketplaceTestSupport.entry(
                id: "io.example.zig-support",
                repository: Self.communityRepository,
                version: "1.0.0",
                archiveURL: Self.communityArchive,
                sha256: try indexChecksum ?? MacPluginPackageDownloader.sha256(of: archive)
            )
        ]).write(to: index)
        let transport = PluginMarketplaceTestSupport.LocalFileTransport(files: [
            Self.communityArchive: archive,
            Self.communityIndex: index,
        ])
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: [:],
                allowsLocalDevelopmentPackages: false,
                hostBundleURL: root.appendingPathComponent("host/Lithe.app", isDirectory: true)
            )
        )
        let service = MacPluginMarketplaceService(
            evaluator: PluginMarketplaceTestSupport.evaluator,
            packageStore: store,
            downloader: MacPluginPackageDownloader(
                transport: transport,
                temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
            ),
            transport: transport,
            applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            bundledOfficialIndexURL: nil,
            platform: "darwin-arm64"
        )
        let source = PluginMarketplaceSource(
            id: sourceKind == .official ? PluginMarketplaceSource.officialID : "source-fixture",
            name: "example/lithe-zig",
            input: Self.communityRepository,
            indexURL: Self.communityIndex,
            repository: Self.communityRepository,
            isEnabled: true
        )
        return Fixture(root: root, service: service, store: store, source: source)
    }

    private func prepare(_ fixture: Fixture) async throws -> PreparedPluginPackage {
        let snapshot = try await fixture.service.refreshIndex(for: fixture.source)
        let entry = try #require(snapshot.index.plugins.first)
        let download = try #require(entry.availability.download)
        return try await fixture.service.prepareInstall(
            entry: entry,
            download: download,
            source: fixture.source,
            approvedPrograms: nil
        )
    }

    @Test
    func communityPackageIsReviewedInstalledAndProtectedAgainstChanges() async throws {
        let fixture = try makeFixture("community")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let prepared = try await prepare(fixture)
        defer { fixture.service.discard(prepared) }
        #expect(prepared.origin == .community)
        #expect(prepared.review.permissions == ["languageServer.launch"])
        #expect(prepared.review.programs.map(\.kind) == [.packagedLanguageServer])
        #expect(prepared.review.programs.first?.path == "bin/zls")
        #expect(prepared.provenance.sourceID == "source-fixture")
        #expect(prepared.provenance.repository == Self.communityRepository)

        let installed = try fixture.store.installPackage(
            from: prepared.packageURL,
            origin: prepared.origin,
            marketplace: prepared.provenance
        )
        #expect(installed.installation.marketplace == prepared.provenance)
        #expect(try fixture.store.scanInstalledPlugins().issues.isEmpty)

        // A changed file must make the package unloadable: the recorded
        // digest is the only integrity proof an unsigned package has.
        try Data("#!/bin/sh\necho changed\n".utf8)
            .write(to: installed.packageURL.appendingPathComponent("bin/zls"))
        let scan = try fixture.store.scanInstalledPlugins()
        #expect(scan.packages.isEmpty)
        #expect(scan.issues.first?.message
            == PluginPackageStoreError.communityContentChanged(installed.descriptor.id).localizedDescription)
    }

    @Test
    func refreshedIndexIsCachedOutsideTheBundleAndReusedOffline() async throws {
        let fixture = try makeFixture("cache")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await fixture.service.refreshIndex(for: fixture.source)
        let cached = try #require(fixture.service.cachedIndex(for: fixture.source))
        #expect(cached.index.plugins.map(\.id) == ["io.example.zig-support"])
        #expect(cached.fetchedAt != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("cache/Lithe/PluginMarketplace/source-fixture/index.json").path))

        fixture.service.removeCache(for: fixture.source)
        #expect(fixture.service.cachedIndex(for: fixture.source) == nil)
    }

    @Test
    func checksumMismatchLeavesNothingToInstall() async throws {
        let fixture = try makeFixture("mismatch", indexChecksum: String(repeating: "a", count: 64))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: MacPluginPackageDownloadError.self) {
            _ = try await prepare(fixture)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appendingPathComponent("tmp").path
        )) ?? []
        #expect(leftovers.isEmpty)
    }

    /// Only Lithe can sign packages, so a third-party source cannot deliver a
    /// package that claims a publisher signature.
    @Test
    func thirdPartyPackageMustBeUnsigned() async throws {
        let fixture = try makeFixture("claims-signature", signatureRequirement: .publisherPackage)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: MacPluginMarketplaceError.communityPackageMustBeUnsigned("io.example.zig-support")) {
            _ = try await prepare(fixture)
        }
    }

    /// Official means the default source and a Lithe signature together.
    @Test
    func officialSourceRefusesUnsignedPackages() async throws {
        let fixture = try makeFixture("official-unsigned", sourceKind: .official)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: MacPluginMarketplaceError.officialPackageNotSigned("io.example.zig-support")) {
            _ = try await prepare(fixture)
        }
    }

    @Test
    func unsignedPackageCannotBeInstalledAsAnOfficialMarketplacePackage() throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("origin")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try DeclarativePluginTestSupport.writePackage(
            at: root.appendingPathComponent("io.example.unsigned", isDirectory: true),
            manifest: DeclarativePluginTestSupport.manifestObject(
                id: "io.example.unsigned",
                version: PluginVersion(major: 1, minor: 0, patch: 0),
                signatureRequirement: .unsigned
            )
        )
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            validator: DeclarativePluginTestSupport.operations
        )

        #expect(throws: PluginPackageStoreError.unsignedPackageNotAllowed(PluginID("io.example.unsigned"))) {
            try store.installPackage(from: package, origin: .marketplace)
        }
        // A community origin without the approved digest is refused too.
        #expect(throws: PluginPackageStoreError.communityContentChanged(PluginID("io.example.unsigned"))) {
            try store.installPackage(from: package, origin: .community)
        }
    }

    @Test
    func sourcesPersistWithTheOfficialSourceFirst() throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("sources")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacPluginMarketplaceService(
            evaluator: PluginMarketplaceTestSupport.evaluator,
            packageStore: MacPluginPackageStore(rootURL: root, validator: DeclarativePluginTestSupport.operations),
            downloader: MacPluginPackageDownloader(transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [:])),
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [:]),
            applicationSupportDirectory: root,
            cacheDirectory: root,
            bundledOfficialIndexURL: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("Plugins/marketplace/index.json")
        )
        #expect(service.loadSources().map(\.id) == [PluginMarketplaceSource.officialID, PluginMarketplaceSource.communityID])
        // The bundled official index keeps the catalog usable offline.
        #expect(service.cachedIndex(for: MacPluginMarketplaceService.officialSource)?.fetchedAt == nil)
        #expect(service.cachedIndex(for: MacPluginMarketplaceService.officialSource) != nil)

        var official = MacPluginMarketplaceService.officialSource
        official.isEnabled = false
        let community = PluginMarketplaceSource(
            id: "source-1",
            name: "example/plugins",
            input: "https://github.com/example/plugins",
            indexURL: "https://raw.githubusercontent.com/example/plugins/HEAD/lithe-plugin-index.json",
            repository: "https://github.com/example/plugins",
            isEnabled: true
        )
        // Saving without Lithe Store records it as removed by the user.
        try service.saveSources([community, official])

        let loaded = service.loadSources()
        #expect(loaded.map(\.id) == [PluginMarketplaceSource.officialID, "source-1"])
        #expect(loaded.first?.isEnabled == false)
        #expect(loaded.first?.indexURL == MacPluginMarketplaceService.officialIndexURL)
    }

    /// Lithe Store is preset as a community source: on by default, its
    /// enabled state persists, a removal is remembered, and a sources file
    /// written before the preset existed gains it once.
    @Test
    func litheStoreIsAPresetRemovableCommunitySource() throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("preset-sources")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacPluginMarketplaceService(
            evaluator: PluginMarketplaceTestSupport.evaluator,
            packageStore: MacPluginPackageStore(rootURL: root, validator: DeclarativePluginTestSupport.operations),
            downloader: MacPluginPackageDownloader(transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [:])),
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [:]),
            applicationSupportDirectory: root,
            cacheDirectory: root,
            bundledOfficialIndexURL: nil
        )

        let store = try #require(service.loadSources().last)
        #expect(store == MacPluginMarketplaceService.communitySource)
        #expect(store.kind == .thirdParty)
        #expect(store.isEnabled)
        #expect(try service.resolveSource(store.input).indexURL == store.indexURL)

        var disabled = store
        disabled.isEnabled = false
        try service.saveSources([MacPluginMarketplaceService.officialSource, disabled])
        #expect(service.loadSources().last?.isEnabled == false)

        try service.saveSources([MacPluginMarketplaceService.officialSource])
        #expect(service.loadSources().map(\.id) == [PluginMarketplaceSource.officialID])

        let sourcesURL = root.appendingPathComponent("Lithe/PluginMarketplace/sources.json")
        try Data(#"{"schemaVersion":1,"sources":[]}"#.utf8).write(to: sourcesURL)
        #expect(service.loadSources().map(\.id) == [PluginMarketplaceSource.officialID, PluginMarketplaceSource.communityID])
    }

    /// A sources file from a release without the preset where the user added
    /// Lithe Store by hand: it stays one source with the user's enabled state
    /// and the ID its installed plugins recorded.
    @Test
    func litheStoreAddedByHandBeforeThePresetIsNotDuplicated() throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("legacy-preset-sources")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacPluginMarketplaceService(
            evaluator: PluginMarketplaceTestSupport.evaluator,
            packageStore: MacPluginPackageStore(rootURL: root, validator: DeclarativePluginTestSupport.operations),
            downloader: MacPluginPackageDownloader(transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [:])),
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [:]),
            applicationSupportDirectory: root,
            cacheDirectory: root,
            bundledOfficialIndexURL: nil
        )
        let sourcesURL = root.appendingPathComponent("Lithe/PluginMarketplace/sources.json")
        try FileManager.default.createDirectory(at: sourcesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeLegacySources(_ input: String) throws -> PluginMarketplaceSource {
            let resolution = try service.resolveSource(input)
            let manual = PluginMarketplaceSource(
                id: PluginMarketplaceSource.id(forIndexURL: resolution.indexURL),
                name: resolution.displayName,
                input: input,
                indexURL: resolution.indexURL,
                repository: resolution.repository,
                isEnabled: false
            )
            try JSONEncoder().encode(LegacySourcesFile(schemaVersion: 1, sources: [manual])).write(to: sourcesURL)
            return manual
        }

        let manual = try writeLegacySources("https://github.com/Lithe-IDEA/Lithe-store")
        #expect(manual.id == PluginMarketplaceSource.communityID)
        let loaded = service.loadSources()
        #expect(loaded.map(\.id) == [PluginMarketplaceSource.officialID, PluginMarketplaceSource.communityID])
        #expect(loaded.last?.isEnabled == false)

        let lowercased = try writeLegacySources("https://github.com/lithe-idea/lithe-store")
        #expect(lowercased.id != PluginMarketplaceSource.communityID)
        #expect(service.loadSources().map(\.id) == [PluginMarketplaceSource.officialID, lowercased.id])
        #expect(service.loadSources().last?.isEnabled == false)
    }

    private struct LegacySourcesFile: Encodable {
        let schemaVersion: Int
        let sources: [PluginMarketplaceSource]
    }

    /// The description follows the app's interface language, including a
    /// region-qualified locale, and falls back to the default text.
    @Test
    func entryDescriptionFollowsTheInterfaceLanguage() throws {
        let index = try PluginMarketplaceTestSupport.evaluator.validateIndex(
            Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("shared/contracts/plugins/v1/fixtures/marketplace/index.json")),
            sourceKind: .official,
            platform: "darwin-arm64"
        )
        let zig = try #require(index.plugins.first { $0.id == "io.example.zig-support" })
        #expect(zig.description(for: Locale(identifier: "zh-Hans")) == "Zig 语言服务器与测试运行集成。")
        #expect(zig.description(for: Locale(identifier: "zh_CN")) == "Zig 语言服务器与测试运行集成。")
        #expect(zig.description(for: Locale(identifier: "en")) == zig.description)
        #expect(zig.description(for: Locale(identifier: "fr")) == zig.description)
    }

    /// The catalog describes what Install would install: Core skips PHP
    /// 1.1.0 (plugin API 2) and offers 1.0.0, so 1.0.0's facts are shown.
    @Test
    func catalogShowsTheInstallableVersionRatherThanTheNewest() throws {
        let index = try PluginMarketplaceTestSupport.evaluator.validateIndex(
            Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("shared/contracts/plugins/v1/fixtures/marketplace/index.json")),
            sourceKind: .official,
            platform: "darwin-arm64"
        )
        let php = try #require(index.plugins.first { $0.id == "dev.lithe.fixture.php-support" })
        #expect(php.latestVersion == "1.1.0")
        #expect(php.availability.download?.version == "1.0.0")
        #expect(php.installableVersion?.version == "1.0.0")
        #expect(php.presentedVersion.version == "1.0.0")
        #expect(php.presentedVersion.releaseDate == php.availability.download?.releaseDate)

        // Nothing installable: the newest version is shown with the reason.
        let future = try #require(index.plugins.first { $0.id == "io.example.future-tools" })
        #expect(future.installableVersion == nil)
        #expect(future.presentedVersion.version == "3.0.0")
    }

    @Test(arguments: ["gradle-provider", "mix-provider"])
    func buildProvidersAreAcceptedByTheMacOSHost(_ fixture: String) throws {
        let fixtures = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures")
        let manifest = try Data(contentsOf: fixtures.appendingPathComponent("\(fixture).plugin.json"))
        // The host declares `buildProviders`, so the requirement no longer
        // blocks the review; a rejection here would name another field.
        _ = try PluginMarketplaceTestSupport.evaluator.installReview(
            manifest: manifest, expectedID: nil, expectedVersion: nil, approvedPrograms: nil
        )
    }

    /// The approval covers what actually runs, not just which executable:
    /// an update that keeps `php` but changes its arguments, after the
    /// approval went through the installation record, must ask again.
    @Test
    func changedRunArgumentsNeedApprovalAgainAfterStorage() throws {
        let fixtures = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures")
        let original = try Data(contentsOf: fixtures.appendingPathComponent("php-support.plugin.json"))
        var manifest = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var providers = try #require(manifest["executionProviders"] as? [[String: Any]])
        var run = try #require(providers[0]["run"] as? [String: Any])
        run["arguments"] = ["-r", "${userArguments}"]
        providers[0]["run"] = run
        manifest["executionProviders"] = providers
        let updated = try JSONSerialization.data(withJSONObject: manifest)

        let evaluator = PluginMarketplaceTestSupport.evaluator
        let first = try evaluator.installReview(
            manifest: original, expectedID: nil, expectedVersion: nil, approvedPrograms: nil
        )
        let stored = try first.programs.map { try PluginProgram(canonicalJSON: $0.canonicalJSON()) }
        let unchanged = try evaluator.installReview(
            manifest: original, expectedID: nil, expectedVersion: nil, approvedPrograms: stored
        )
        #expect(unchanged.newPrograms.isEmpty)

        let update = try evaluator.installReview(
            manifest: updated, expectedID: nil, expectedVersion: nil, approvedPrograms: stored
        )
        #expect(update.newPrograms.map(\.kind) == [.run])
        #expect(update.newPrograms.first?.argumentTemplate("arguments") == ["-r", "${userArguments}"])
    }

    @Test
    func sourceResolutionUsesCoreRules() throws {
        let resolution = try PluginMarketplaceTestSupport.evaluator.resolveSource(" https://github.com/example/plugins ")
        #expect(resolution.indexURL == "https://raw.githubusercontent.com/example/plugins/HEAD/lithe-plugin-index.json")
        #expect(throws: DeclarativePluginRejection.self) {
            _ = try PluginMarketplaceTestSupport.evaluator.resolveSource("http://example.com/index.json")
        }
    }
}
