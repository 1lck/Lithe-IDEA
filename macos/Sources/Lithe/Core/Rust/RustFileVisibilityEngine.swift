import Foundation
import LitheCoreContracts

/// Thin adapter over Core's `workspace.classifyVisibility` and `workspace.visibilityDefaults`.
/// The built-in lists, the glob matcher and the file-versus-folder rules live in
/// rust/lithe-core-rules; Windows runs the same Rust source as wasm. This type only encodes the
/// request and decodes the answer. Each call is one synchronous FFI round trip, and callers send
/// every entry of a listing together instead of calling once per file.
///
/// `LitheCoreContracts` does not link the Rust bridge, so it finds this class by its Objective-C
/// name (see `FileVisibilityEngines`). Keep the name in sync with that lookup.
@objc(LitheRustFileVisibilityEngine)
final class RustFileVisibilityEngine: NSObject, FileVisibilityEngine, @unchecked Sendable {
    private struct EntryPayload: Encodable {
        let path: String
        let isDirectory: Bool?

        private enum CodingKeys: String, CodingKey { case path, isDirectory }

        // A nil kind must reach Core as an absent field; Core reads absence as "unknown".
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(isDirectory, forKey: .isDirectory)
        }
    }

    private struct ClassifyRequest: Encodable {
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
        let entries: [EntryPayload]
    }

    private struct ClassifyResponse: Decodable {
        let hidden: [Bool]
        let watchedDespiteHiding: [Bool]
    }

    private struct DefaultsResponse: Decodable {
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
        let builtInPatterns: [String]
        let configurationDirectory: String
        let configurationPattern: String
    }

    private struct EmptyPayload: Encodable {}

    private let core: RustCoreBridge

    override init() {
        core = RustCoreBridge()
        super.init()
    }

    func defaults() -> FileVisibilityDefaults {
        let result: Result<DefaultsResponse, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "workspace.visibilityDefaults", payload: EmptyPayload()
        )
        switch result {
        case let .success(response):
            return FileVisibilityDefaults(
                hiddenDirectoryNames: response.hiddenDirectoryNames,
                hiddenFilePatterns: response.hiddenFilePatterns,
                builtInPatterns: response.builtInPatterns,
                configurationDirectory: response.configurationDirectory,
                configurationPattern: response.configurationPattern
            )
        case .failure:
            // A valid request cannot fail unless the linked Core is broken, and there is no
            // second implementation to fall back to.
            fatalError("workspace.visibilityDefaults failed")
        }
    }

    func classify(
        _ queries: [FileVisibilityQuery],
        hiddenDirectoryNames: [String],
        hiddenFilePatterns: [String]
    ) -> [FileVisibilityVerdict] {
        guard !queries.isEmpty else { return [] }
        let result: Result<ClassifyResponse, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "workspace.classifyVisibility",
            payload: ClassifyRequest(
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns,
                entries: queries.map { EntryPayload(path: $0.relativePath, isDirectory: $0.isDirectory) }
            )
        )
        switch result {
        case let .success(response):
            return zip(response.hidden, response.watchedDespiteHiding).map {
                FileVisibilityVerdict(hidden: $0, watchedDespiteHiding: $1)
            }
        case .failure:
            assertionFailure("workspace.classifyVisibility failed")
            return queries.map { _ in FileVisibilityVerdict(hidden: false, watchedDespiteHiding: false) }
        }
    }
}
