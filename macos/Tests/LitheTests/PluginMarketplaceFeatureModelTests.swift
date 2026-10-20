import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

/// User-visible marketplace state transitions with in-memory doubles: when a
/// community install must be confirmed, which source an installed plugin is
/// tied to, and how refresh failures keep the last catalog.
@MainActor
@Suite("Plugin marketplace feature model")
struct PluginMarketplaceFeatureModelTests {
    private static let community = PluginMarketplaceSource(
        id: "source-community",
        name: "example/plugins",
        input: "https://github.com/example/plugins",
        indexURL: "https://raw.githubusercontent.com/example/plugins/HEAD/lithe-plugin-index.json",
        repository: "https://github.com/example/plugins",
        isEnabled: true
    )

    @Test
    func communityInstallWaitsForConfirmationAndCancelDiscardsTheDownload() async throws {
        let (feature, service, manager) = try makeModel()
        let offer = try communityOffer(feature)

        await feature.install(offer)

        let confirmation = try #require(feature.pendingConfirmation)
        #expect(!confirmation.isUpdate)
        #expect(manager.installed.isEmpty)
        feature.cancelPendingInstallation()
        #expect(feature.pendingConfirmation == nil)
        #expect(service.discarded == [confirmation.id])
        #expect(manager.installed.isEmpty)
    }

    @Test
    func confirmedCommunityInstallRecordsTheApprovedPrograms() async throws {
        let (feature, service, manager) = try makeModel()

        await feature.install(try communityOffer(feature))
        feature.confirmPendingInstallation()

        let install = try #require(manager.installed.first)
        #expect(install.origin == .community)
        #expect(install.provenance.approvedPrograms == service.programs.map { try! $0.canonicalJSON() })
        #expect(feature.pendingConfirmation == nil)
    }

    @Test
    func officialInstallDoesNotAskForConfirmation() async throws {
        let (feature, service, manager) = try makeModel()
        service.origin = .marketplace
        let listing = try #require(feature.listings.first { $0.pluginID.rawValue == "dev.lithe.plugin.sample" })
        let offer = try #require(feature.offer(for: listing))

        await feature.install(offer)

        #expect(feature.pendingConfirmation == nil)
        #expect(manager.installed.map(\.origin) == [.marketplace])
    }

    @Test
    func updateWithoutNewProgramsInstallsDirectly() async throws {
        let (feature, service, manager) = try makeModel()
        manager.snapshots = [try installedSnapshot(version: "0.9.0", approved: service.programs)]
        service.newPrograms = []
        let offer = try communityOffer(feature)
        #expect(feature.installState(for: offer) == .updateAvailable(installed: "0.9.0", available: "1.0.0"))

        await feature.install(offer)

        #expect(feature.pendingConfirmation == nil)
        #expect(manager.installed.count == 1)
        #expect(service.lastApprovedPrograms == service.programs)
    }

    @Test
    func updateThatStartsNewProgramsAsksAgain() async throws {
        let (feature, service, manager) = try makeModel()
        manager.snapshots = [try installedSnapshot(version: "0.9.0", approved: [])]
        service.newPrograms = service.programs

        await feature.install(try communityOffer(feature))

        let confirmation = try #require(feature.pendingConfirmation)
        #expect(confirmation.isUpdate)
        #expect(manager.installed.isEmpty)
    }

    /// A plugin installed from one source is never updated from another.
    @Test
    func installedPluginIsTiedToItsSource() async throws {
        let (feature, _, manager) = try makeModel(alsoListCommunityInOfficial: true)
        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: [])]
        let listing = try #require(feature.listings.first { $0.pluginID.rawValue == "io.example.zig-support" })
        #expect(listing.offers.count == 2)

        let official = try #require(listing.offers.first { $0.source.isOfficial })
        #expect(feature.installState(for: official) == .installedFromOtherSource(sourceName: "example/plugins"))
        #expect(feature.offer(for: listing)?.source.id == Self.community.id)
    }

    /// The marketplace detail offers Uninstall under the Installed tab's rule:
    /// installed plugin packages only, never required or built-in ones.
    @Test
    func uninstallIsOfferedOnlyForRemovablePluginPackages() throws {
        let (feature, _, manager) = try makeModel()
        let pluginID = PluginID("io.example.zig-support")
        #expect(!feature.canUninstall(pluginID))

        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: [])]
        #expect(feature.canUninstall(pluginID))

        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: [], isRequired: true)]
        #expect(!feature.canUninstall(pluginID))

        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: [], status: .removed)]
        #expect(!feature.canUninstall(pluginID))

        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: [], origin: .bundled)]
        #expect(!feature.canUninstall(pluginID))
    }

    /// A freshly installed plugin is only loaded at the next launch, so the
    /// marketplace must not present it as ready.
    @Test
    func installedPluginWaitingForRestartIsReported() throws {
        let (feature, _, manager) = try makeModel()
        let pluginID = PluginID("io.example.zig-support")
        #expect(!feature.requiresRestart(pluginID))

        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: [], requiresRestart: true)]
        #expect(feature.requiresRestart(pluginID))

        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: [])]
        #expect(!feature.requiresRestart(pluginID))
    }

    @Test
    func unsupportedPlatformIsReported() throws {
        let (feature, _, _) = try makeModel()
        let listing = try #require(feature.listings.first { $0.pluginID.rawValue == "io.example.windows-only" })
        let offer = try #require(feature.offer(for: listing))

        guard case .unsupported = feature.installState(for: offer) else {
            Issue.record("expected unsupported, got \(feature.installState(for: offer))")
            return
        }
    }

    @Test
    func failedRefreshKeepsTheLastCatalogAndReportsTheError() async throws {
        let (feature, service, _) = try makeModel()
        service.refreshError = MacPluginPackageDownloadError.httpStatus(503)

        await feature.refresh(sourceID: Self.community.id)

        #expect(feature.listings.contains { $0.pluginID.rawValue == "io.example.zig-support" })
        #expect(feature.sourceStatuses[Self.community.id]?.error
            == MacPluginPackageDownloadError.httpStatus(503).localizedDescription)
        #expect(feature.sourceStatuses[Self.community.id]?.isRefreshing == false)
    }

    @Test
    func sourcesCannotBeAddedTwiceAndTheOfficialSourceStays() async throws {
        let (feature, service, _) = try makeModel()
        service.resolution = PluginMarketplaceSourceResolution(
            indexURL: Self.community.indexURL,
            repository: Self.community.repository,
            displayName: Self.community.name
        )

        await #expect(throws: PluginMarketplaceFeatureError.sourceAlreadyAdded(Self.community.name)) {
            try await feature.addSource(Self.community.input)
        }
        #expect(throws: PluginMarketplaceFeatureError.officialSourceCannotBeRemoved) {
            try feature.removeSource(PluginMarketplaceSource.officialID)
        }
        try feature.removeSource(Self.community.id)
        #expect(feature.sources.map(\.id) == [PluginMarketplaceSource.officialID])
        #expect(!feature.listings.contains { $0.pluginID.rawValue == "io.example.zig-support" })
    }

    /// Install from Lithe Store → remove the source → add the same repository
    /// again (in another case): the plugin still updates and reinstalls from it.
    @Test
    func litheStoreAddedAgainKeepsItsInstalledPlugins() async throws {
        let store = MacPluginMarketplaceService.communitySource
        let (feature, service, manager) = try makeModel(communitySource: store)
        manager.snapshots = [try installedSnapshot(version: "0.9.0", approved: service.programs, sourceID: store.id)]
        let index = try #require(service.indexes[store.id])

        try feature.removeSource(store.id)
        #expect(feature.availableUpdate(for: PluginID("io.example.zig-support")) == nil)

        service.indexes[store.id] = index
        service.resolution = PluginMarketplaceSourceResolution(
            indexURL: "https://raw.githubusercontent.com/lithe-idea/lithe-store/HEAD/lithe-plugin-index.json",
            repository: "https://github.com/lithe-idea/lithe-store",
            displayName: "lithe-idea/lithe-store"
        )
        try await feature.addSource("https://github.com/lithe-idea/lithe-store")

        #expect(feature.sources.map(\.id) == [PluginMarketplaceSource.officialID, PluginMarketplaceSource.communityID])
        let update = try #require(feature.availableUpdate(for: PluginID("io.example.zig-support")))
        #expect(update.source.id == store.id)
        #expect(feature.installState(for: update) == .updateAvailable(installed: "0.9.0", available: "1.0.0"))
        await #expect(throws: PluginMarketplaceFeatureError.sourceAlreadyAdded("lithe-idea/lithe-store")) {
            try await feature.addSource(store.input)
        }
    }

    @Test
    func listingsFilterBySourceAndSortByLastUpdate() throws {
        let (feature, _, _) = try makeModel()

        let byDate = feature.visibleListings(query: "", sourceID: nil, sortOrder: .lastUpdated)
        #expect(byDate.first?.pluginID.rawValue == "io.example.zig-support")
        let officialOnly = feature.visibleListings(
            query: "",
            sourceID: PluginMarketplaceSource.officialID,
            sortOrder: .name
        )
        #expect(officialOnly.map(\.pluginID.rawValue) == ["dev.lithe.plugin.sample"])
        #expect(feature.visibleListings(query: "zig", sourceID: nil, sortOrder: .name).count == 1)
    }

    @Test
    func diskInstallAlwaysWaitsForApprovalAndCancelDiscardsTheSnapshot() async throws {
        let (feature, service, manager) = try makeModel()
        manager.snapshots = [try installedSnapshot(version: "1.0.0", approved: service.programs)]

        await feature.installFromDisk(at: URL(fileURLWithPath: "/fixture/local.zip"))

        let confirmation = try #require(feature.pendingConfirmation)
        guard case .disk(let prepared) = confirmation.package else {
            Issue.record("expected a disk approval")
            return
        }
        #expect(confirmation.isUpdate)
        #expect(confirmation.review.programs == service.programs)
        #expect(prepared.provenance.fileName == "local.zip")
        #expect(manager.diskInstalls.isEmpty)
        feature.cancelPendingInstallation()
        #expect(feature.pendingConfirmation == nil)
        #expect(service.discarded == [confirmation.id])
        #expect(manager.diskInstalls.isEmpty)
    }

    @Test
    func confirmedDiskInstallUsesOnlyLocalProvenanceAndCleansTheSnapshot() async throws {
        let (feature, service, manager) = try makeModel()
        await feature.installFromDisk(at: URL(fileURLWithPath: "/fixture/local.zip"))
        let confirmation = try #require(feature.pendingConfirmation)

        feature.confirmPendingInstallation()

        let install = try #require(manager.diskInstalls.first)
        #expect(install.approvedPrograms == service.programs.map { try! $0.canonicalJSON() })
        #expect(manager.installed.isEmpty)
        #expect(service.discarded == [confirmation.id])
        #expect(feature.pendingConfirmation == nil)
    }

    @Test
    func failedDiskCommitDiscardsTheSnapshotAndShowsTheError() async throws {
        let (feature, service, manager) = try makeModel()
        manager.diskInstallError = CocoaError(.fileWriteNoPermission)
        await feature.installFromDisk(at: URL(fileURLWithPath: "/fixture/local.zip"))
        let confirmation = try #require(feature.pendingConfirmation)

        feature.confirmPendingInstallation()

        #expect(feature.diskInstallError == manager.diskInstallError?.localizedDescription)
        #expect(feature.pendingConfirmation == nil)
        #expect(service.discarded == [confirmation.id])
        #expect(manager.diskInstalls.isEmpty)
    }

    @Test
    func marketplaceDoesNotClaimALocallyInstalledPlugin() throws {
        let (feature, _, manager) = try makeModel()
        var snapshot = try installedSnapshot(version: "0.9.0", approved: [])
        snapshot.disk = PluginDiskProvenance(
            fileName: "local.zip", archiveSHA256: nil,
            contentDigest: String(repeating: "5", count: 64), approvedPrograms: []
        )
        manager.snapshots = [snapshot]
        let offer = try communityOffer(feature)

        #expect(feature.installedSourceID(for: snapshot.id) == nil)
        #expect(feature.availableUpdate(for: snapshot.id) == nil)
        #expect(feature.installState(for: offer) == .managedOutsideMarketplace(version: "0.9.0"))
    }

    /// Go and PHP Support moved to Lithe Store. A cached official index that
    /// still lists the old package must not offer it, and an installed copy
    /// is no longer tied to the official source for updates or reinstall.
    @Test
    func officialPluginMovedToTheCommunityHasNoOfficialSource() throws {
        let retiredID = OfficialPluginCatalog.phpPluginID
        let (feature, _, manager) = try makeModel(staleOfficialIDs: [retiredID.rawValue])
        manager.snapshots = [try retiredPHPSnapshot(status: .installed)]

        #expect(OfficialPluginCatalog.entry(for: retiredID)?.communityReplacementID
            == PluginID("io.github.lithe-idea.php-support"))
        #expect(!feature.listings.contains { $0.pluginID == retiredID })
        #expect(feature.listings.contains { $0.pluginID.rawValue == "dev.lithe.plugin.sample" })
        #expect(feature.installedSourceID(for: retiredID) == nil)
        #expect(feature.availableUpdate(for: retiredID) == nil)
        #expect(feature.canUninstall(retiredID))
    }

    /// The community plugin declares the same language as the retired one,
    /// so it cannot be installed until the old package is gone after restart.
    @Test
    func communityReplacementWaitsUntilTheRetiredPluginIsRemoved() async throws {
        let replacementID = "io.github.lithe-idea.php-support"
        let (feature, service, manager) = try makeModel(extraCommunityIDs: [replacementID])
        service.origin = .community
        let listing = try #require(feature.listings.first { $0.pluginID.rawValue == replacementID })
        let offer = try #require(feature.offer(for: listing))

        manager.snapshots = [try retiredPHPSnapshot(status: .installed)]
        #expect(feature.installState(for: offer) == .blockedByRetiredPlugin(name: "PHP Support", uninstallPending: false))
        await feature.install(offer)
        #expect(feature.pendingConfirmation == nil)
        #expect(manager.installed.isEmpty)

        manager.snapshots = [try retiredPHPSnapshot(status: .uninstallPending, hasChangesPendingRestart: true)]
        #expect(feature.installState(for: offer) == .blockedByRetiredPlugin(name: "PHP Support", uninstallPending: true))
        #expect(feature.hasChangesPendingRestart)

        // After the restart the old package is gone.
        manager.snapshots = []
        #expect(feature.installState(for: offer) == .installable)
        #expect(!feature.hasChangesPendingRestart)
        await feature.install(offer)
        #expect(feature.pendingConfirmation != nil)
    }

    private func retiredPHPSnapshot(
        status: PluginInstallationStatus,
        hasChangesPendingRestart: Bool = false
    ) throws -> PluginManagementSnapshot {
        let manifest = try DeclarativePluginTestSupport.officialDescriptor("PhpSupport").pluginManifest
        return PluginManagementSnapshot(
            manifest: manifest,
            origin: .marketplace,
            installationStatus: status,
            isEnabled: true,
            isRequired: false,
            isRunning: false,
            isQuarantined: false,
            isSuppressedBySafeMode: false,
            requiresRestart: false,
            canRollback: false,
            statusMessage: "Enabled",
            marketplace: PluginMarketplaceProvenance(
                sourceID: PluginMarketplaceSource.officialID,
                sourceName: "Lithe",
                repository: "https://github.com/Lithe-IDEA/Lithe-IDEA",
                archiveSHA256: String(repeating: "1", count: 64),
                contentDigest: String(repeating: "2", count: 64),
                approvedPrograms: []
            ),
            hasChangesPendingRestart: hasChangesPendingRestart
        )
    }

    @Test
    func aNewApprovalDiscardsThePreviousSnapshot() async throws {
        let (feature, service, _) = try makeModel()
        await feature.installFromDisk(at: URL(fileURLWithPath: "/fixture/first.zip"))
        let first = try #require(feature.pendingConfirmation)
        await feature.install(try communityOffer(feature))
        let second = try #require(feature.pendingConfirmation)

        #expect(first.id != second.id)
        #expect(service.discarded == [first.id])
        feature.confirmPendingInstallation(id: first.id)
        #expect(feature.pendingConfirmation?.id == second.id)
        feature.cancelPendingInstallation()
        #expect(service.discarded == [first.id, second.id])
    }

    @Test
    func closingThePageDiscardsPendingAndLateDiskReviews() async throws {
        let (feature, service, manager) = try makeModel()
        await feature.installFromDisk(at: URL(fileURLWithPath: "/fixture/first.zip"))
        let first = try #require(feature.pendingConfirmation)
        feature.endInstallationSession()
        #expect(service.discarded == [first.id])
        #expect(feature.pendingConfirmation == nil)

        // Deterministically close the page while the service owns preparation,
        // before its result returns to the feature.
        service.onDiskPreparation = { feature.endInstallationSession() }
        await feature.installFromDisk(at: URL(fileURLWithPath: "/fixture/late.zip"))
        #expect(feature.pendingConfirmation == nil)
        #expect(service.discarded.count == 2)
        #expect(manager.diskInstalls.isEmpty)
        #expect(!feature.isPreparingDiskInstall)
    }

    // MARK: Doubles

    private func makeModel(
        alsoListCommunityInOfficial: Bool = false,
        staleOfficialIDs: [String] = [],
        extraCommunityIDs: [String] = [],
        communitySource community: PluginMarketplaceSource = Self.community
    ) throws -> (PluginMarketplaceFeatureModel, FakeMarketplaceService, FakePluginManager) {
        let official = MacPluginMarketplaceService.officialSource
        var officialEntries = [
            Self.entry(id: "dev.lithe.plugin.sample", date: "2026-09-01", platforms: ["darwin-arm64"])
        ] + staleOfficialIDs.map {
            Self.entry(id: $0, date: "2026-10-13", platforms: ["darwin-arm64"])
        }
        if alsoListCommunityInOfficial {
            officialEntries.append(Self.entry(id: "io.example.zig-support", date: "2026-10-01", platforms: ["darwin-arm64"]))
        }
        let service = FakeMarketplaceService(
            sources: [official, community],
            indexes: [
                official.id: PluginMarketplaceIndex(plugins: officialEntries, rejected: []),
                community.id: PluginMarketplaceIndex(plugins: [
                    Self.entry(id: "io.example.windows-only", date: "2026-08-01", platforms: ["windows-x64"]),
                    Self.entry(id: "io.example.zig-support", date: "2026-10-10", platforms: ["darwin-arm64"]),
                ] + extraCommunityIDs.map {
                    Self.entry(id: $0, date: "2026-10-20", platforms: ["darwin-arm64"])
                }, rejected: []),
            ]
        )
        let manager = FakePluginManager()
        let feature = PluginMarketplaceFeatureModel(service: service, pluginManager: manager)
        feature.loadIfNeeded()
        return (feature, service, manager)
    }

    private func communityOffer(_ feature: PluginMarketplaceFeatureModel) throws -> PluginMarketplaceOffer {
        let listing = try #require(feature.listings.first { $0.pluginID.rawValue == "io.example.zig-support" })
        return try #require(listing.offers.first { $0.source.id == Self.community.id })
    }

    private func installedSnapshot(
        version: String,
        approved: [PluginProgram],
        sourceID: String = Self.community.id,
        origin: PluginInstallationOrigin = .community,
        status: PluginInstallationStatus = .installed,
        isRequired: Bool = false,
        requiresRestart: Bool = false
    ) throws -> PluginManagementSnapshot {
        let manifest = try DeclarativePluginTestSupport.descriptor(
            DeclarativePluginTestSupport.manifestObject(
                id: "io.example.zig-support",
                version: try #require(PluginVersion(version)),
                signatureRequirement: .unsigned
            )
        ).pluginManifest
        return PluginManagementSnapshot(
            manifest: manifest,
            origin: origin,
            installationStatus: status,
            isEnabled: true,
            isRequired: isRequired,
            isRunning: false,
            isQuarantined: false,
            isSuppressedBySafeMode: false,
            requiresRestart: requiresRestart,
            canRollback: false,
            statusMessage: "Enabled",
            marketplace: PluginMarketplaceProvenance(
                sourceID: sourceID,
                sourceName: Self.community.name,
                repository: "https://github.com/example/lithe-zig",
                archiveSHA256: String(repeating: "1", count: 64),
                contentDigest: String(repeating: "2", count: 64),
                approvedPrograms: try approved.map { try $0.canonicalJSON() }
            )
        )
    }

    private static func entry(id: String, date: String, platforms: [String]) -> PluginMarketplaceEntry {
        let availability: PluginMarketplaceAvailability = platforms.contains("darwin-arm64")
            ? .available(PluginMarketplaceDownload(
                version: "1.0.0",
                pluginAPIVersion: 1,
                releaseDate: date,
                downloadURL: "https://github.com/example/\(id)/releases/download/v1/p.zip",
                sha256: String(repeating: "3", count: 64)
            ))
            : .unsupported(code: "plugin.index.platformUnsupported", platform: "darwin-arm64", message: "unsupported")
        return PluginMarketplaceEntry(
            id: id,
            name: id,
            author: "Example",
            repository: "https://github.com/example/\(id)",
            homepage: nil,
            description: "Fixture",
            tags: [],
            license: "MIT",
            icon: nil,
            platforms: platforms,
            latestVersion: "1.0.0",
            latestReleaseDate: date,
            availability: availability,
            versions: []
        )
    }
}

@MainActor
private final class FakeMarketplaceService: PluginMarketplaceServicing {
    let platform = "darwin-arm64"
    var sources: [PluginMarketplaceSource]
    var indexes: [String: PluginMarketplaceIndex]
    var refreshError: Error?
    var onDiskPreparation: (() -> Void)?
    var resolution = PluginMarketplaceSourceResolution(indexURL: "https://example.com/i.json", repository: nil, displayName: "example.com")
    var origin: PluginInstallationOrigin = .community
    let programs = [PluginProgram(json: .object([
        "kind": .string("packagedLanguageServer"),
        "languageID": .string("zig"),
        "path": .string("bin/zls"),
        "arguments": .array([]),
    ]))]
    lazy var newPrograms: [PluginProgram] = programs
    private(set) var discarded: [UUID] = []
    private(set) var lastApprovedPrograms: [PluginProgram]?

    init(sources: [PluginMarketplaceSource], indexes: [String: PluginMarketplaceIndex]) {
        self.sources = sources
        self.indexes = indexes
    }

    func loadSources() -> [PluginMarketplaceSource] { sources }
    func saveSources(_ sources: [PluginMarketplaceSource]) throws { self.sources = sources }
    func resolveSource(_ input: String) throws -> PluginMarketplaceSourceResolution { resolution }

    func cachedIndex(for source: PluginMarketplaceSource) -> PluginMarketplaceIndexSnapshot? {
        indexes[source.id].map { PluginMarketplaceIndexSnapshot(index: $0, fetchedAt: nil) }
    }

    func refreshIndex(for source: PluginMarketplaceSource) async throws -> PluginMarketplaceIndexSnapshot {
        if let refreshError { throw refreshError }
        return PluginMarketplaceIndexSnapshot(index: indexes[source.id] ?? .init(plugins: [], rejected: []), fetchedAt: Date())
    }

    func removeCache(for source: PluginMarketplaceSource) {
        indexes[source.id] = nil
    }

    func prepareInstall(
        entry: PluginMarketplaceEntry,
        download: PluginMarketplaceDownload,
        source: PluginMarketplaceSource,
        approvedPrograms: [PluginProgram]?
    ) async throws -> PreparedPluginPackage {
        lastApprovedPrograms = approvedPrograms
        let directory = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        return PreparedPluginPackage(
            id: UUID(),
            pluginID: PluginID(entry.id),
            version: download.version,
            sourceID: source.id,
            packageURL: directory,
            temporaryDirectory: directory,
            review: PluginInstallReview(
                pluginID: entry.id,
                version: download.version,
                permissions: ["languageServer.launch"],
                programs: programs,
                newPrograms: newPrograms
            ),
            provenance: PluginMarketplaceProvenance(
                sourceID: source.id,
                sourceName: source.name,
                repository: entry.repository,
                archiveSHA256: download.sha256,
                contentDigest: String(repeating: "4", count: 64),
                approvedPrograms: try programs.map { try $0.canonicalJSON() }
            ),
            origin: origin
        )
    }

    func prepareDiskInstall(at url: URL) async throws -> PreparedDiskPluginPackage {
        onDiskPreparation?()
        let directory = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        return PreparedDiskPluginPackage(
            id: UUID(), pluginID: PluginID("io.example.zig-support"),
            displayName: "Zig Support", author: "Example",
            packageURL: directory, temporaryDirectory: directory,
            review: PluginInstallReview(
                pluginID: "io.example.zig-support", version: "1.0.0",
                permissions: ["languageServer.launch"], programs: programs, newPrograms: programs
            ),
            provenance: PluginDiskProvenance(
                fileName: url.lastPathComponent, archiveSHA256: nil,
                contentDigest: String(repeating: "5", count: 64),
                approvedPrograms: try programs.map { try $0.canonicalJSON() }
            ),
            origin: origin
        )
    }

    func discard(_ prepared: PreparedPluginPackage) {
        discarded.append(prepared.id)
    }

    func discard(_ prepared: PreparedDiskPluginPackage) {
        discarded.append(prepared.id)
    }
}

@MainActor
private final class FakePluginManager: PluginManaging {
    struct Install: Equatable {
        let origin: PluginInstallationOrigin
        let provenance: PluginMarketplaceProvenance
    }

    var snapshots: [PluginManagementSnapshot] = []
    var issues: [PluginManagementIssue] = []
    private(set) var installed: [Install] = []
    private(set) var diskInstalls: [PluginDiskProvenance] = []
    var diskInstallError: Error?

    func setEnabled(_ enabled: Bool, for pluginID: PluginID) async throws {}
    func setSetting(_ value: ToolingJSONValue?, id settingID: String, for pluginID: PluginID) throws {}

    func installMarketplacePackage(
        at packageURL: URL,
        origin: PluginInstallationOrigin,
        provenance: PluginMarketplaceProvenance
    ) throws {
        installed.append(Install(origin: origin, provenance: provenance))
    }

    func installDiskPackage(at packageURL: URL, provenance: PluginDiskProvenance) throws {
        if let diskInstallError { throw diskInstallError }
        diskInstalls.append(provenance)
    }

    func installPackage(at packageURL: URL) throws {}
    func rollback(_ pluginID: PluginID) throws {}
    func uninstall(_ pluginID: PluginID) async throws {}
    func restore(_ pluginID: PluginID) throws {}
}
