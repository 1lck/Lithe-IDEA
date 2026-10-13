import Foundation
import LitheCoreContracts

struct MacWorkspaceDependencyStore: WorkspaceDependencyStoring, Sendable {
    private let storage: any FileStorage

    init(storage: any FileStorage) {
        self.storage = storage
    }

    func loadDependencyConfiguration(
        workspaceURL: URL
    ) throws -> WorkspaceDependencyConfiguration? {
        let value = try decodeIfPresent(
            WorkspaceDependencyConfiguration.self,
            at: configurationURL(workspaceURL)
        )
        guard value?.version == nil || value?.version == WorkspaceDependencyConfiguration.currentVersion else {
            throw WorkspaceDependencyStoreError.unsupportedVersion
        }
        return value
    }

    func saveDependencyConfiguration(
        _ configuration: WorkspaceDependencyConfiguration,
        workspaceURL: URL
    ) throws {
        try write(configuration, to: configurationURL(workspaceURL))
    }

    func loadDependencyIndexes(workspaceURL: URL) throws -> WorkspaceDependencyIndexes? {
        let value = try decodeIfPresent(
            WorkspaceDependencyIndexes.self,
            at: indexURL(workspaceURL)
        )
        guard value?.version == nil || value?.version == WorkspaceDependencyIndexes.currentVersion else {
            throw WorkspaceDependencyStoreError.unsupportedVersion
        }
        return value
    }

    func saveDependencyIndexes(
        _ indexes: WorkspaceDependencyIndexes,
        workspaceURL: URL
    ) throws {
        try write(indexes, to: indexURL(workspaceURL))
    }

    private func configurationURL(_ workspaceURL: URL) -> URL {
        dependencyDirectory(workspaceURL).appendingPathComponent("config.json")
    }

    private func indexURL(_ workspaceURL: URL) -> URL {
        dependencyDirectory(workspaceURL).appendingPathComponent("index.json")
    }

    private func dependencyDirectory(_ workspaceURL: URL) -> URL {
        workspaceURL.standardizedFileURL
            .appendingPathComponent(".lithe", isDirectory: true)
            .appendingPathComponent("dependencies", isDirectory: true)
    }

    private func decodeIfPresent<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> Value? {
        guard storage.fileExists(at: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: storage.readData(from: url, options: []))
        } catch {
            throw WorkspaceDependencyStoreError.invalidJSON(url.lastPathComponent)
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        do {
            try storage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try storage.writeData(encoder.encode(value), to: url, options: .atomic)
        } catch {
            throw WorkspaceDependencyStoreError.writeFailed(error.localizedDescription)
        }
    }
}

private enum WorkspaceDependencyStoreError: LocalizedError {
    case invalidJSON(String)
    case unsupportedVersion
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let name):
            "The workspace dependency configuration in \(name) is invalid."
        case .unsupportedVersion:
            "The workspace dependency configuration uses an unsupported version."
        case .writeFailed(let details):
            "Unable to save workspace dependency configuration: \(details)"
        }
    }
}
