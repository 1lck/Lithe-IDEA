import Foundation
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning

// Note: 插件市场的来源、信任与安装确认见 .agents/notes/implemented/feature/2026-10-12-plugin-marketplace.md
/// macOS marketplace I/O. Sources live in Application Support, fetched
/// indexes in Caches, and downloads in a private temporary directory; the
/// bundled official index is only ever read. Rust Core decides validity,
/// availability, and the install review.
@MainActor
final class MacPluginMarketplaceService: PluginMarketplaceServicing {
    static let officialIndexURL =
        "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json"
    static let officialRepository = "https://github.com/Lithe-IDEA/Lithe-IDEA"
    private static let maximumIndexBytes: Int64 = 5 * 1_048_576
    private static let sourcesSchemaVersion = 1

    let platform: String
    private let evaluator: any PluginMarketplaceEvaluating
    private let packageStore: MacPluginPackageStore
    private let downloader: any MacPluginPackageDownloading
    private let transport: any MacPluginMarketplaceTransport
    private let sourcesURL: URL
    private let cacheRootURL: URL
    private let bundledOfficialIndexURL: URL?
    private let fileManager: FileManager
    private var preparedDirectories: [UUID: URL] = [:]

    init(
        evaluator: any PluginMarketplaceEvaluating,
        packageStore: MacPluginPackageStore,
        downloader: any MacPluginPackageDownloading,
        transport: any MacPluginMarketplaceTransport,
        applicationSupportDirectory: URL,
        cacheDirectory: URL,
        bundledOfficialIndexURL: URL?,
        platform: String = MacPluginMarketplaceService.currentPlatform,
        fileManager: FileManager = .default
    ) {
        self.evaluator = evaluator
        self.packageStore = packageStore
        self.downloader = downloader
        self.transport = transport
        sourcesURL = applicationSupportDirectory
            .appendingPathComponent("Lithe/PluginMarketplace/sources.json", isDirectory: false)
        cacheRootURL = cacheDirectory
            .appendingPathComponent("Lithe/PluginMarketplace", isDirectory: true)
        self.bundledOfficialIndexURL = bundledOfficialIndexURL
        self.platform = platform
        self.fileManager = fileManager
    }

    nonisolated static let currentPlatform: String = {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
    }()

    static var officialSource: PluginMarketplaceSource {
        PluginMarketplaceSource(
            id: PluginMarketplaceSource.officialID,
            name: "Lithe",
            input: officialIndexURL,
            indexURL: officialIndexURL,
            repository: officialRepository,
            isEnabled: true
        )
    }

    // MARK: Sources

    func loadSources() -> [PluginMarketplaceSource] {
        var official = Self.officialSource
        guard let data = try? Data(contentsOf: sourcesURL),
              let file = try? JSONDecoder().decode(SourcesFile.self, from: data),
              file.schemaVersion == Self.sourcesSchemaVersion else {
            return [official]
        }
        // The official entry is rebuilt from host constants; only its
        // enabled state is the user's.
        official.isEnabled = file.sources.first { $0.id == official.id }?.isEnabled ?? true
        let thirdParty = file.sources.filter { $0.id != official.id && $0.kind == .thirdParty }
        return [official] + thirdParty
    }

    func saveSources(_ sources: [PluginMarketplaceSource]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(SourcesFile(schemaVersion: Self.sourcesSchemaVersion, sources: sources))
        try fileManager.createDirectory(
            at: sourcesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: sourcesURL, options: .atomic)
    }

    func resolveSource(_ input: String) throws -> PluginMarketplaceSourceResolution {
        try evaluator.resolveSource(input)
    }

    // MARK: Indexes

    func cachedIndex(for source: PluginMarketplaceSource) -> PluginMarketplaceIndexSnapshot? {
        let cacheURL = indexCacheURL(for: source)
        if let data = try? Data(contentsOf: cacheURL),
           let index = try? evaluator.validateIndex(data, sourceKind: source.kind, platform: platform) {
            let fetchedAt = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return PluginMarketplaceIndexSnapshot(index: index, fetchedAt: fetchedAt)
        }
        guard source.isOfficial,
              let bundledOfficialIndexURL,
              let data = try? Data(contentsOf: bundledOfficialIndexURL),
              let index = try? evaluator.validateIndex(data, sourceKind: .official, platform: platform) else {
            return nil
        }
        return PluginMarketplaceIndexSnapshot(index: index, fetchedAt: nil)
    }

    func refreshIndex(for source: PluginMarketplaceSource) async throws -> PluginMarketplaceIndexSnapshot {
        guard let url = URL(string: source.indexURL) else {
            throw MacPluginPackageDownloadError.invalidEndpoint
        }
        let data = try await transport.data(from: url, maximumBytes: Self.maximumIndexBytes)
        // Only an index Core accepts replaces the cache, so a broken upload
        // never hides the last working catalog.
        let index = try evaluator.validateIndex(data, sourceKind: source.kind, platform: platform)
        let cacheURL = indexCacheURL(for: source)
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        return PluginMarketplaceIndexSnapshot(index: index, fetchedAt: Date())
    }

    func removeCache(for source: PluginMarketplaceSource) {
        try? fileManager.removeItem(at: indexCacheURL(for: source).deletingLastPathComponent())
    }

    private func indexCacheURL(for source: PluginMarketplaceSource) -> URL {
        cacheRootURL
            .appendingPathComponent(source.id, isDirectory: true)
            .appendingPathComponent("index.json", isDirectory: false)
    }

    // MARK: Installation

    func prepareInstall(
        entry: PluginMarketplaceEntry,
        download: PluginMarketplaceDownload,
        source: PluginMarketplaceSource,
        approvedPrograms: [PluginProgram]?
    ) async throws -> PreparedPluginPackage {
        guard let archiveURL = URL(string: download.downloadURL) else {
            throw MacPluginPackageDownloadError.invalidEndpoint
        }
        let pluginID = PluginID(entry.id)
        let downloaded = try await downloader.download(
            archiveURL: archiveURL,
            expectedSHA256: download.sha256,
            pluginID: pluginID
        )
        do {
            let prepared = try verify(
                downloaded,
                entry: entry,
                download: download,
                source: source,
                approvedPrograms: approvedPrograms
            )
            preparedDirectories[prepared.id] = downloaded.temporaryDirectory
            return prepared
        } catch {
            try? fileManager.removeItem(at: downloaded.temporaryDirectory)
            throw error
        }
    }

    func discard(_ prepared: PreparedPluginPackage) {
        guard let directory = preparedDirectories.removeValue(forKey: prepared.id) else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// Checks, in order, the declaration, the trust the source can grant, the
    /// install review against the index entry, and the package as a whole.
    private func verify(
        _ downloaded: MacDownloadedPluginPackage,
        entry: PluginMarketplaceEntry,
        download: PluginMarketplaceDownload,
        source: PluginMarketplaceSource,
        approvedPrograms: [PluginProgram]?
    ) throws -> PreparedPluginPackage {
        let packageURL = downloaded.packageURL
        let descriptor = try packageStore.inspectPackage(at: packageURL)
        let requirement = descriptor.pluginManifest.vendor.signatureRequirement
        let origin: PluginInstallationOrigin
        switch source.kind {
        case .official:
            // Official means the default source *and* a Lithe signature.
            guard requirement == .publisherPackage else {
                throw MacPluginMarketplaceError.officialPackageNotSigned(entry.id)
            }
            origin = .marketplace
        case .thirdParty:
            guard requirement == .unsigned else {
                throw MacPluginMarketplaceError.communityPackageMustBeUnsigned(entry.id)
            }
            origin = .community
        }
        let manifestData = try Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        let review = try evaluator.installReview(
            manifest: manifestData,
            expectedID: entry.id,
            expectedVersion: download.version,
            approvedPrograms: approvedPrograms
        )
        let provenance = PluginMarketplaceProvenance(
            sourceID: source.id,
            sourceName: source.name,
            repository: entry.repository,
            archiveSHA256: download.sha256,
            contentDigest: try PluginPackageSignature.contentDigest(packageAt: packageURL, fileManager: fileManager),
            approvedPrograms: try review.programs.map { try $0.canonicalJSON() }
        )
        _ = try packageStore.verifyCandidatePackage(at: packageURL, origin: origin, marketplace: provenance)
        return PreparedPluginPackage(
            id: UUID(),
            pluginID: descriptor.id,
            version: download.version,
            sourceID: source.id,
            packageURL: packageURL,
            temporaryDirectory: downloaded.temporaryDirectory,
            review: review,
            provenance: provenance,
            origin: origin
        )
    }

    private struct SourcesFile: Codable {
        let schemaVersion: Int
        let sources: [PluginMarketplaceSource]
    }
}

enum MacPluginMarketplaceError: Error, Equatable, LocalizedError {
    case officialPackageNotSigned(String)
    case communityPackageMustBeUnsigned(String)

    var errorDescription: String? {
        switch self {
        case .officialPackageNotSigned(let id):
            "Plugin \(id) from the official repository is not signed by Lithe, so it was not installed."
        case .communityPackageMustBeUnsigned(let id):
            "Community plugin \(id) must declare \"signatureRequirement\": \"none\"; only Lithe can publish signed plugins."
        }
    }
}
