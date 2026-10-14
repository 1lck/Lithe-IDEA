import Foundation
import LitheCoreContracts
import LitheModuleAPI
@testable import Lithe

/// Builds marketplace archives and indexes on disk so marketplace tests run
/// the real Rust Core validation without touching the network.
enum PluginMarketplaceTestSupport {
    static var evaluator: RustPluginMarketplaceOperations {
        RustPluginMarketplaceOperations(core: RustCoreBridge())
    }

    static func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-marketplace-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Zips `directory` (keeping its name) with a bounded `ditto` run.
    static func zip(_ directory: URL, to archive: URL) throws -> URL {
        let result = MacProcessRunner().run(ProcessRequest(
            executablePath: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", directory.path, archive.path],
            timeoutMilliseconds: 30_000
        ))
        guard result.exitCode == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        return archive
    }

    /// Serves fixed files by URL; any other URL is a 404.
    struct LocalFileTransport: MacPluginMarketplaceTransport {
        let files: [String: URL]

        func data(from url: URL, maximumBytes: Int64) async throws -> Data {
            guard let file = files[url.absoluteString] else {
                throw MacPluginPackageDownloadError.httpStatus(404)
            }
            return try Data(contentsOf: file)
        }

        func download(from url: URL, maximumBytes: Int64) async throws -> URL {
            guard let file = files[url.absoluteString] else {
                throw MacPluginPackageDownloadError.httpStatus(404)
            }
            let owned = FileManager.default.temporaryDirectory
                .appendingPathComponent("lithe-plugin-transfer-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: owned)
            return owned
        }
    }

    /// One index entry with a single darwin archive.
    static func entry(
        id: String,
        repository: String,
        version: String,
        archiveURL: String,
        sha256: String,
        platforms: [String] = ["darwin-arm64", "darwin-x64"]
    ) -> [String: Any] {
        [
            "id": id,
            "name": "Fixture \(id)",
            "author": "Example Developer",
            "repository": repository,
            "description": "Fixture plugin for marketplace tests.",
            "tags": ["fixture"],
            "license": "MIT",
            "versions": [[
                "version": version,
                "pluginAPIVersion": 1,
                "releaseDate": "2026-10-12",
                "downloads": [[
                    "platforms": platforms,
                    "downloadURL": archiveURL,
                    "sha256": sha256
                ]]
            ]]
        ]
    }

    static func indexData(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "plugins": entries], options: [.sortedKeys])
    }
}
