#if DEBUG
import Foundation

/// Debug-only marketplace mirror for isolated verification builds. When
/// `LITHE_PLUGIN_MARKETPLACE_FIXTURE_ROOT` names a directory, every
/// marketplace request for `https://<host>/<path>` reads
/// `<root>/<host>/<path>` instead of the network, so the full download,
/// checksum, review, and install flow can be exercised without publishing a
/// release. Release builds never compile this type.
struct MacPluginMarketplaceFixtureTransport: MacPluginMarketplaceTransport {
    static let environmentKey = "LITHE_PLUGIN_MARKETPLACE_FIXTURE_ROOT"
    let root: URL

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return Self(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    func data(from url: URL, maximumBytes: Int64) async throws -> Data {
        let file = try fileURL(for: url)
        let data = try Data(contentsOf: file)
        guard Int64(data.count) <= maximumBytes else {
            throw MacPluginPackageDownloadError.archiveTooLarge(maximumBytes)
        }
        return data
    }

    func download(from url: URL, maximumBytes: Int64) async throws -> URL {
        let file = try fileURL(for: url)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= maximumBytes else {
            throw MacPluginPackageDownloadError.archiveTooLarge(maximumBytes)
        }
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-transfer-\(UUID().uuidString)", isDirectory: false)
        try FileManager.default.copyItem(at: file, to: owned)
        return owned
    }

    private func fileURL(for url: URL) throws -> URL {
        guard url.scheme == "https", let host = url.host,
              !url.path.split(separator: "/").contains("..") else {
            throw MacPluginPackageDownloadError.invalidEndpoint
        }
        let file = root.appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent(String(url.path.dropFirst()), isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw MacPluginPackageDownloadError.httpStatus(404)
        }
        return file
    }
}
#endif
