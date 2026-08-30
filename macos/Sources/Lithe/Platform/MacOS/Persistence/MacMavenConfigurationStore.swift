import CryptoKit
import Foundation
import LitheCoreContracts

struct MacMavenConfigurationStore: MavenConfigurationStoring, Sendable {
    private let storage: any FileStorage

    init(storage: any FileStorage) {
        self.storage = storage
    }

    func loadMavenConfiguration(
        workspaceURL: URL,
        reactorPath: String
    ) throws -> MavenStoredConfiguration {
        let portable = try decodeIfPresent(
            MavenPortableConfiguration.self,
            at: portableConfigurationURL(workspaceURL: workspaceURL)
        )
        let local = try decodeIfPresent(
            MavenLocalConfiguration.self,
            at: localConfigurationURL(workspaceURL: workspaceURL, reactorPath: reactorPath)
        )
        guard portable?.version == nil || portable?.version == MavenPortableConfiguration.currentVersion,
              local?.version == nil || local?.version == MavenLocalConfiguration.currentVersion else {
            throw MacMavenConfigurationStoreError.unsupportedVersion
        }
        return MavenStoredConfiguration(portable: portable, local: local)
    }

    func saveMavenConfiguration(
        _ configuration: MavenStoredConfiguration,
        workspaceURL: URL,
        reactorPath: String
    ) throws {
        try write(
            configuration.portable,
            to: portableConfigurationURL(workspaceURL: workspaceURL)
        )
        try write(
            configuration.local,
            to: localConfigurationURL(workspaceURL: workspaceURL, reactorPath: reactorPath)
        )
    }

    private func portableConfigurationURL(workspaceURL: URL) -> URL {
        workspaceURL.standardizedFileURL
            .appendingPathComponent(".lithe", isDirectory: true)
            .appendingPathComponent("maven", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func localConfigurationURL(workspaceURL: URL, reactorPath: String) -> URL {
        let identity = Self.storageIdentity(
            workspacePath: workspaceURL.standardizedFileURL.path,
            reactorPath: reactorPath
        )
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return storage.applicationSupportDirectory()
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("Maven", isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }

    static func storageIdentity(workspacePath: String, reactorPath: String) -> String {
        workspacePath + "\0" + reactorPath
    }

    private func decodeIfPresent<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> Value? {
        guard storage.fileExists(at: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: storage.readData(from: url, options: []))
        } catch {
            throw MacMavenConfigurationStoreError.invalidConfiguration(url.lastPathComponent)
        }
    }

    private func write<Value: Encodable>(_ value: Value?, to url: URL) throws {
        guard let value else {
            if storage.fileExists(at: url) {
                try storage.removeItem(at: url)
            }
            return
        }
        do {
            try storage.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try storage.writeData(encoder.encode(value), to: url, options: .atomic)
        } catch {
            throw MacMavenConfigurationStoreError.writeFailed(error.localizedDescription)
        }
    }
}

private enum MacMavenConfigurationStoreError: LocalizedError {
    case invalidConfiguration(String)
    case unsupportedVersion
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let name):
            "The Maven configuration in \(name) is invalid."
        case .unsupportedVersion:
            "The Maven configuration was created by an unsupported version of Lithe."
        case .writeFailed(let details):
            "Unable to save Maven configuration: \(details)"
        }
    }
}
