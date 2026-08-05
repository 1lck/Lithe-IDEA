import CryptoKit
import Foundation

/// Stores AI credentials in Lithe's local application data instead of Keychain.
///
/// The file is private to the current user and its contents are lightly obfuscated
/// to avoid keeping API keys as readable plaintext. This is not a replacement for
/// Keychain encryption: a local process with access to the user's files can still
/// recover the value.
final class MacLocalSecretStore: SecureStore, @unchecked Sendable {
    private struct FileContents: Codable {
        let version: Int
        var values: [String: String]
    }

    private static let fileVersion = 1
    private static let obfuscationSeed = Data("Lithe-local-secrets-v1".utf8)

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lithe/ai-secrets.json")
    }

    func read(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let contents = try? loadContents(),
              let encodedValue = contents.values[key],
              let data = Data(base64Encoded: encodedValue) else {
            return nil
        }
        return String(data: transform(data, key: key), encoding: .utf8)
    }

    func write(_ value: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var contents = (try? loadContents()) ?? FileContents(
            version: Self.fileVersion,
            values: [:]
        )
        let data = transform(Data(value.utf8), key: key)
        contents.values[key] = data.base64EncodedString()
        try saveContents(contents)
    }

    func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard var contents = try? loadContents() else { return }
        contents.values.removeValue(forKey: key)
        if contents.values.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        } else {
            try saveContents(contents)
        }
    }

    private func loadContents() throws -> FileContents {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return FileContents(version: Self.fileVersion, values: [:])
        }
        let data = try Data(contentsOf: fileURL)
        let contents = try JSONDecoder().decode(FileContents.self, from: data)
        guard contents.version == Self.fileVersion else {
            return FileContents(version: Self.fileVersion, values: [:])
        }
        return contents
    }

    private func saveContents(_ contents: FileContents) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder().encode(contents)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func transform(_ data: Data, key: String) -> Data {
        let digest = SHA256.hash(data: Self.obfuscationSeed + Data(key.utf8))
        let mask = Array(digest)
        return Data(data.enumerated().map { index, byte in
            byte ^ mask[index % mask.count]
        })
    }
}
