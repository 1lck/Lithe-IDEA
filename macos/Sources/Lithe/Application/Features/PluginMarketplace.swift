import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件市场的来源、信任与安装确认见 .agents/notes/implemented/feature/2026-10-12-plugin-marketplace.md

/// A plugin repository the user browses. The official source is built in and
/// can be disabled but not removed; every other source is third-party.
struct PluginMarketplaceSource: Equatable, Codable, Sendable, Identifiable {
    static let officialID = "lithe-official"

    let id: String
    let name: String
    /// What the user entered, or the official index URL.
    let input: String
    let indexURL: String
    /// GitHub repository of the source itself, when it lives on GitHub.
    let repository: String?
    var isEnabled: Bool

    var kind: PluginMarketplaceSourceKind { id == Self.officialID ? .official : .thirdParty }
    var isOfficial: Bool { kind == .official }
}

/// A validated index together with when it was fetched; `fetchedAt` is nil
/// for the copy bundled with the application.
struct PluginMarketplaceIndexSnapshot: Equatable, Sendable {
    let index: PluginMarketplaceIndex
    let fetchedAt: Date?
}

/// A downloaded package that passed checksum, declaration, and trust checks
/// and waits for the user's decision. Only the service that produced it may
/// install or discard it.
struct PreparedPluginPackage: Equatable, Sendable, Identifiable {
    let id: UUID
    let pluginID: PluginID
    let version: String
    let sourceID: String
    let packageURL: URL
    let temporaryDirectory: URL
    let review: PluginInstallReview
    let provenance: PluginMarketplaceProvenance
    let origin: PluginInstallationOrigin
}

/// Marketplace I/O: source persistence, index fetching and caching, archive
/// download and verification. Platform adapters implement it; the feature
/// model owns every user-visible state transition.
@MainActor
protocol PluginMarketplaceServicing: AnyObject {
    /// Platform identifier used for availability, for example `darwin-arm64`.
    var platform: String { get }

    func loadSources() -> [PluginMarketplaceSource]
    func saveSources(_ sources: [PluginMarketplaceSource]) throws
    func resolveSource(_ input: String) throws -> PluginMarketplaceSourceResolution
    /// Last fetched index, or the bundled copy for the official source.
    func cachedIndex(for source: PluginMarketplaceSource) -> PluginMarketplaceIndexSnapshot?
    func refreshIndex(for source: PluginMarketplaceSource) async throws -> PluginMarketplaceIndexSnapshot
    func removeCache(for source: PluginMarketplaceSource)
    /// Downloads the archive, verifies the index checksum, validates the
    /// package and its trust for the source, and reviews its programs.
    func prepareInstall(
        entry: PluginMarketplaceEntry,
        download: PluginMarketplaceDownload,
        source: PluginMarketplaceSource,
        approvedPrograms: [PluginProgram]?
    ) async throws -> PreparedPluginPackage
    func discard(_ prepared: PreparedPluginPackage)
}

/// One source's listing of a plugin.
struct PluginMarketplaceOffer: Equatable, Identifiable {
    let source: PluginMarketplaceSource
    let entry: PluginMarketplaceEntry

    var id: String { source.id }
}

/// What the marketplace can do with a plugin on this host.
enum PluginMarketplaceInstallState: Equatable {
    case installable
    case installed(version: String)
    case updateAvailable(installed: String, available: String)
    /// Installed from another source; updates only come from that source.
    case installedFromOtherSource(sourceName: String)
    /// Built in or installed from disk, not managed by the marketplace.
    case managedOutsideMarketplace(version: String)
    case unsupported(message: String)
}

/// All sources' listings of one plugin ID.
struct PluginMarketplaceListing: Equatable, Identifiable {
    let pluginID: PluginID
    let offers: [PluginMarketplaceOffer]

    var id: PluginID { pluginID }
}

/// A pending decision about a community package's permissions and programs.
struct PluginInstallConfirmation: Equatable, Identifiable {
    let prepared: PreparedPluginPackage
    let entry: PluginMarketplaceEntry
    let sourceName: String
    let isUpdate: Bool

    var id: UUID { prepared.id }
}

/// State of Settings › Plugins › Marketplace and the plugin repository list.
///
/// Nothing is fetched until the page first appears; the bundled official
/// index and earlier caches keep the catalog usable offline.
@MainActor
final class PluginMarketplaceFeatureModel: ObservableObject {
    enum SortOrder: String, CaseIterable {
        case name
        case lastUpdated
    }

    struct SourceStatus: Equatable {
        var isRefreshing = false
        var fetchedAt: Date?
        var error: String?
        var rejectedEntries: [PluginMarketplaceRejectedEntry] = []
    }

    @Published private(set) var sources: [PluginMarketplaceSource] = []
    @Published private(set) var sourceStatuses: [String: SourceStatus] = [:]
    @Published private(set) var listings: [PluginMarketplaceListing] = []
    /// Plugins with a download, verification, or installation in progress.
    @Published private(set) var busyPluginIDs: Set<PluginID> = []
    @Published private(set) var errors: [PluginID: String] = [:]
    @Published var pendingConfirmation: PluginInstallConfirmation?
    /// The source chosen in the detail pane for plugins listed by several.
    @Published var selectedSourceIDs: [PluginID: String] = [:]

    private let service: any PluginMarketplaceServicing
    private let pluginManager: any PluginManaging
    private var indexes: [String: PluginMarketplaceIndex] = [:]
    private var didRefreshThisSession = false
    private var didLoad = false

    init(service: any PluginMarketplaceServicing, pluginManager: any PluginManaging) {
        self.service = service
        self.pluginManager = pluginManager
    }

    var platform: String { service.platform }

    /// Reads persisted sources and cached indexes without touching the network.
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        sources = service.loadSources()
        for source in sources {
            if let snapshot = service.cachedIndex(for: source) {
                indexes[source.id] = snapshot.index
                sourceStatuses[source.id, default: SourceStatus()].fetchedAt = snapshot.fetchedAt
                sourceStatuses[source.id, default: SourceStatus()].rejectedEntries = snapshot.index.rejected
            }
        }
        rebuildListings()
    }

    /// Refreshes enabled sources once per launch, when the page first appears.
    func refreshIfNeeded() async {
        loadIfNeeded()
        guard !didRefreshThisSession else { return }
        didRefreshThisSession = true
        await refreshAll()
    }

    func refreshAll() async {
        loadIfNeeded()
        await withTaskGroup(of: Void.self) { group in
            for source in sources where source.isEnabled {
                group.addTask { await self.refresh(sourceID: source.id) }
            }
        }
    }

    func refresh(sourceID: String) async {
        guard let source = sources.first(where: { $0.id == sourceID }),
              sourceStatuses[sourceID]?.isRefreshing != true else { return }
        sourceStatuses[sourceID, default: SourceStatus()].isRefreshing = true
        do {
            let snapshot = try await service.refreshIndex(for: source)
            indexes[sourceID] = snapshot.index
            sourceStatuses[sourceID, default: SourceStatus()].fetchedAt = snapshot.fetchedAt
            sourceStatuses[sourceID, default: SourceStatus()].rejectedEntries = snapshot.index.rejected
            sourceStatuses[sourceID, default: SourceStatus()].error = nil
        } catch {
            // The previous index stays usable; the failure is shown next to
            // the source instead of emptying the catalog.
            sourceStatuses[sourceID, default: SourceStatus()].error = error.localizedDescription
        }
        sourceStatuses[sourceID, default: SourceStatus()].isRefreshing = false
        rebuildListings()
    }

    /// Adds a third-party source and fetches it. The source is kept even if
    /// the first fetch fails so the user can fix the network and refresh.
    func addSource(_ input: String) async throws {
        loadIfNeeded()
        let resolution = try service.resolveSource(input)
        let source = PluginMarketplaceSource(
            id: Self.sourceID(forIndexURL: resolution.indexURL),
            name: resolution.displayName,
            input: input.trimmingCharacters(in: .whitespacesAndNewlines),
            indexURL: resolution.indexURL,
            repository: resolution.repository,
            isEnabled: true
        )
        guard !sources.contains(where: { $0.id == source.id || $0.indexURL == source.indexURL }) else {
            throw PluginMarketplaceFeatureError.sourceAlreadyAdded(source.name)
        }
        try service.saveSources(sources + [source])
        sources.append(source)
        await refresh(sourceID: source.id)
    }

    func removeSource(_ sourceID: String) throws {
        guard let source = sources.first(where: { $0.id == sourceID }), !source.isOfficial else {
            throw PluginMarketplaceFeatureError.officialSourceCannotBeRemoved
        }
        let remaining = sources.filter { $0.id != sourceID }
        try service.saveSources(remaining)
        sources = remaining
        service.removeCache(for: source)
        indexes[sourceID] = nil
        sourceStatuses[sourceID] = nil
        rebuildListings()
    }

    func setSourceEnabled(_ enabled: Bool, sourceID: String) throws {
        guard let position = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        var updated = sources
        updated[position].isEnabled = enabled
        try service.saveSources(updated)
        sources = updated
        rebuildListings()
    }

    // MARK: Listings

    func offer(for listing: PluginMarketplaceListing) -> PluginMarketplaceOffer? {
        if let installedSourceID = installedSourceID(for: listing.pluginID),
           let offer = listing.offers.first(where: { $0.source.id == installedSourceID }) {
            return offer
        }
        if let selected = selectedSourceIDs[listing.pluginID],
           let offer = listing.offers.first(where: { $0.source.id == selected }) {
            return offer
        }
        return listing.offers.first
    }

    func visibleListings(query: String, sourceID: String?, sortOrder: SortOrder) -> [PluginMarketplaceListing] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = listings.compactMap { listing -> PluginMarketplaceListing? in
            let offers = sourceID.map { id in listing.offers.filter { $0.source.id == id } } ?? listing.offers
            guard !offers.isEmpty,
                  query.isEmpty || offers.contains(where: { Self.matches($0.entry, query: query) }) else {
                return nil
            }
            return PluginMarketplaceListing(pluginID: listing.pluginID, offers: offers)
        }
        switch sortOrder {
        case .name:
            return filtered.sorted {
                let left = $0.offers[0].entry.name.localizedLowercase
                let right = $1.offers[0].entry.name.localizedLowercase
                return left == right ? $0.pluginID < $1.pluginID : left < right
            }
        case .lastUpdated:
            return filtered.sorted {
                let left = $0.offers.map(\.entry.latestReleaseDate).max() ?? ""
                let right = $1.offers.map(\.entry.latestReleaseDate).max() ?? ""
                return left == right ? $0.pluginID < $1.pluginID : left > right
            }
        }
    }

    func installState(for offer: PluginMarketplaceOffer) -> PluginMarketplaceInstallState {
        let pluginID = PluginID(offer.entry.id)
        if let snapshot = pluginManager.snapshots.first(where: { $0.id == pluginID }) {
            let installedVersion = snapshot.manifest.version.description
            guard let installedSourceID = installedSourceID(for: pluginID) else {
                return .managedOutsideMarketplace(version: installedVersion)
            }
            guard installedSourceID == offer.source.id else {
                let name = sources.first { $0.id == installedSourceID }?.name ?? installedSourceID
                return .installedFromOtherSource(sourceName: name)
            }
            if let available = offer.entry.availability.download,
               let availableVersion = PluginVersion(available.version),
               availableVersion > snapshot.manifest.version {
                return .updateAvailable(installed: installedVersion, available: available.version)
            }
            return .installed(version: installedVersion)
        }
        switch offer.entry.availability {
        case .available:
            return .installable
        case .unsupported(_, _, let message):
            return .unsupported(message: message)
        }
    }

    /// Update offered for an installed plugin from its recorded source.
    func availableUpdate(for pluginID: PluginID) -> PluginMarketplaceOffer? {
        guard let listing = listings.first(where: { $0.pluginID == pluginID }),
              let offer = offer(for: listing),
              case .updateAvailable = installState(for: offer) else { return nil }
        return offer
    }

    /// Downloads the installed plugin again from its recorded source, for
    /// example after its files were damaged.
    func reinstall(_ pluginID: PluginID) async {
        guard let sourceID = installedSourceID(for: pluginID),
              let offer = listings.first(where: { $0.pluginID == pluginID })?
                .offers.first(where: { $0.source.id == sourceID }) else {
            errors[pluginID] = PluginMarketplaceFeatureError.notListed(pluginID.rawValue).localizedDescription
            return
        }
        await install(offer)
    }

    /// The marketplace source a plugin was installed from. Official packages
    /// installed before the marketplace existed belong to the official source.
    func installedSourceID(for pluginID: PluginID) -> String? {
        guard let snapshot = pluginManager.snapshots.first(where: { $0.id == pluginID }) else { return nil }
        if let provenance = snapshot.marketplace {
            return provenance.sourceID
        }
        if snapshot.origin == .marketplace, OfficialPluginCatalog.entry(for: pluginID) != nil {
            return PluginMarketplaceSource.officialID
        }
        return nil
    }

    // MARK: Installation

    /// Installs or updates from `offer`. Official packages install directly;
    /// community packages wait for confirmation on first install and when an
    /// update starts programs the user has not approved.
    func install(_ offer: PluginMarketplaceOffer) async {
        let pluginID = PluginID(offer.entry.id)
        guard !busyPluginIDs.contains(pluginID),
              let download = offer.entry.availability.download else { return }
        busyPluginIDs.insert(pluginID)
        errors[pluginID] = nil
        defer { busyPluginIDs.remove(pluginID) }

        let installed = pluginManager.snapshots.first { $0.id == pluginID }
        let approved = installed?.marketplace.map { provenance in
            provenance.approvedPrograms.compactMap { try? PluginProgram(canonicalJSON: $0) }
        }
        do {
            let prepared = try await service.prepareInstall(
                entry: offer.entry,
                download: download,
                source: offer.source,
                approvedPrograms: approved
            )
            let isUpdate = installed != nil
            let needsConfirmation = prepared.origin == .community
                && (!isUpdate || approved == nil || !prepared.review.newPrograms.isEmpty)
            if needsConfirmation {
                if let pendingConfirmation {
                    service.discard(pendingConfirmation.prepared)
                }
                pendingConfirmation = PluginInstallConfirmation(
                    prepared: prepared,
                    entry: offer.entry,
                    sourceName: offer.source.name,
                    isUpdate: isUpdate
                )
                return
            }
            try commit(prepared)
        } catch {
            errors[pluginID] = error.localizedDescription
        }
    }

    func confirmPendingInstallation() {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        do {
            try commit(confirmation.prepared)
        } catch {
            errors[confirmation.prepared.pluginID] = error.localizedDescription
        }
    }

    func cancelPendingInstallation() {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        service.discard(confirmation.prepared)
    }

    private func commit(_ prepared: PreparedPluginPackage) throws {
        defer { service.discard(prepared) }
        try pluginManager.installMarketplacePackage(
            at: prepared.packageURL,
            origin: prepared.origin,
            provenance: prepared.provenance
        )
        objectWillChange.send()
    }

    // MARK: Helpers

    private func rebuildListings() {
        var offersByID: [String: [PluginMarketplaceOffer]] = [:]
        // Source order is the user's list order with the official source
        // first, so it is also the default choice for a shared ID.
        for source in sources where source.isEnabled {
            for entry in indexes[source.id]?.plugins ?? [] {
                offersByID[entry.id, default: []].append(PluginMarketplaceOffer(source: source, entry: entry))
            }
        }
        listings = offersByID.keys.sorted().map {
            PluginMarketplaceListing(pluginID: PluginID($0), offers: offersByID[$0] ?? [])
        }
    }

    private static func matches(_ entry: PluginMarketplaceEntry, query: String) -> Bool {
        ([entry.name, entry.author, entry.description, entry.id] + entry.tags
            + (entry.localizedDescriptions.map { Array($0.values) } ?? []))
            .contains { $0.lowercased().contains(query) }
    }

    /// Stable, filesystem-safe ID for a third-party source, derived from its
    /// index URL so the same source cannot be added twice.
    static func sourceID(forIndexURL indexURL: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in indexURL.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "source-" + String(hash, radix: 16)
    }
}

enum PluginMarketplaceFeatureError: Error, Equatable, LocalizedError {
    case sourceAlreadyAdded(String)
    case officialSourceCannotBeRemoved
    case notListed(String)

    var errorDescription: String? {
        switch self {
        case .sourceAlreadyAdded(let name):
            "The plugin repository \(name) has already been added."
        case .officialSourceCannotBeRemoved:
            "The official Lithe plugin repository cannot be removed. Disable it instead."
        case .notListed(let id):
            "Plugin \(id) is not listed by the plugin repository it was installed from. Refresh the repository and try again."
        }
    }
}
