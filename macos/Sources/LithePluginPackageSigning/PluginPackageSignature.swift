import CryptoKit
import Foundation

/// Signs and verifies the complete file tree of an official native plugin package.
///
/// The package signature authenticates the release artifact independently from
/// Apple's code-signing identity. Native bundle validation remains required so
/// malformed or unsigned bundles cannot be loaded.
public enum PluginPackageSignature {
    public static let schemaVersion = 2
    public static let algorithm = "ed25519"
    public static let signatureFileName = "lithe-plugin-signature.json"
    public static let stablePublisherPublicKeyBase64 = "5g83oIZu4TjOQr5g9KJcrNd2pgdXyEnvhJIXtrPoPyw="

    public enum Channel: String, Codable, Sendable {
        case stable
        case preview
    }

    public static func keyID(for channel: Channel) -> String {
        "lithe-official-plugins-\(channel.rawValue)-v1"
    }

    public struct Document: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let algorithm: String
        public let keyID: String
        public let channel: Channel
        public let pluginID: String
        public let pluginVersion: String
        public let files: [String: String]
        public let signature: String

        public init(
            schemaVersion: Int = PluginPackageSignature.schemaVersion,
            algorithm: String = PluginPackageSignature.algorithm,
            channel: Channel,
            keyID: String? = nil,
            pluginID: String,
            pluginVersion: String,
            files: [String: String],
            signature: String
        ) {
            self.schemaVersion = schemaVersion
            self.algorithm = algorithm
            self.channel = channel
            self.keyID = keyID ?? PluginPackageSignature.keyID(for: channel)
            self.pluginID = pluginID
            self.pluginVersion = pluginVersion
            self.files = files
            self.signature = signature
        }
    }

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidPackageRoot
        case missingManifest
        case invalidManifest
        case unsupportedFile(String)
        case fileListMismatch
        case fileDigestMismatch(String)
        case invalidDocument
        case invalidSignature
        case publicKeyUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidPackageRoot:
                return "The plugin package root is invalid."
            case .missingManifest:
                return "The plugin package manifest is missing."
            case .invalidManifest:
                return "The plugin package manifest is invalid."
            case .unsupportedFile(let path):
                return "The plugin package contains an unsupported file: \(path)."
            case .fileListMismatch:
                return "The plugin package file list does not match its signature."
            case .fileDigestMismatch(let path):
                return "The plugin package file was changed after signing: \(path)."
            case .invalidDocument:
                return "The plugin package signature document is invalid."
            case .invalidSignature:
                return "The plugin package signature is invalid."
            case .publicKeyUnavailable:
                return "The official plugin signing key is unavailable."
            }
        }
    }

    public static func makeDocument(
        packageAt packageURL: URL,
        pluginID: String,
        pluginVersion: String,
        channel: Channel,
        privateKey: Curve25519.Signing.PrivateKey,
        fileManager: FileManager = .default
    ) throws -> Document {
        let files = try fileDigests(
            packageAt: packageURL,
            fileManager: fileManager
        )
        let payload = canonicalPayload(
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            channel: channel,
            files: files
        )
        return Document(
            channel: channel,
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            files: files,
            signature: try privateKey.signature(for: payload).base64EncodedString()
        )
    }

    public static func verify(
        packageAt packageURL: URL,
        pluginID: String,
        pluginVersion: String,
        expectedChannel: Channel,
        document: Document,
        publicKey: Curve25519.Signing.PublicKey,
        fileManager: FileManager = .default
    ) throws {
        guard document.schemaVersion == schemaVersion,
              document.algorithm == algorithm,
              document.channel == expectedChannel,
              document.keyID == keyID(for: expectedChannel),
              document.pluginID == pluginID,
              document.pluginVersion == pluginVersion,
              let signature = Data(base64Encoded: document.signature),
              signature.count == 64 else {
            throw Error.invalidDocument
        }

        let actualFiles = try fileDigests(
            packageAt: packageURL,
            fileManager: fileManager
        )
        guard Set(actualFiles.keys) == Set(document.files.keys) else {
            throw Error.fileListMismatch
        }
        for path in actualFiles.keys.sorted() {
            guard actualFiles[path] == document.files[path] else {
                throw Error.fileDigestMismatch(path)
            }
        }

        let payload = canonicalPayload(
            pluginID: document.pluginID,
            pluginVersion: document.pluginVersion,
            channel: document.channel,
            files: document.files
        )
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw Error.invalidSignature
        }
    }

    public static func write(
        _ document: Document,
        to packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(
            to: packageURL.appendingPathComponent(signatureFileName),
            options: [.atomic]
        )
    }

    public static func read(
        from packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> Document {
        let signatureURL = packageURL.appendingPathComponent(signatureFileName)
        guard fileManager.fileExists(atPath: signatureURL.path) else {
            throw Error.invalidDocument
        }
        do {
            return try JSONDecoder().decode(Document.self, from: Data(contentsOf: signatureURL))
        } catch {
            throw Error.invalidDocument
        }
    }

    private static func fileDigests(
        packageAt packageURL: URL,
        fileManager: FileManager
    ) throws -> [String: String] {
        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Error.invalidPackageRoot
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw Error.invalidPackageRoot
        }

        var digests: [String: String] = [:]
        for case let candidate as URL in enumerator {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            let relativePath = resolvedCandidate.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !relativePath.isEmpty else { continue }
            guard values.isSymbolicLink != true else {
                throw Error.unsupportedFile(relativePath)
            }
            if values.isDirectory == true { continue }
            guard relativePath != signatureFileName else { continue }
            guard !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  !relativePath.contains("\0"),
                  !relativePath.contains("\n"),
                  !relativePath.contains("\r") else {
                throw Error.unsupportedFile(relativePath)
            }
            let data = try Data(contentsOf: resolvedCandidate, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            digests[relativePath] = digest
        }
        return digests
    }

    private static func canonicalPayload(
        pluginID: String,
        pluginVersion: String,
        channel: Channel,
        files: [String: String]
    ) -> Data {
        var lines = [
            "schemaVersion=\(schemaVersion)",
            "algorithm=\(algorithm)",
            "keyID=\(keyID(for: channel))",
            "channel=\(channel.rawValue)",
            "pluginID=\(token(pluginID))",
            "pluginVersion=\(token(pluginVersion))"
        ]
        lines.append(contentsOf: files.keys.sorted().map { path in
            "file=\(token(path))=\(files[path]!)"
        })
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func token(_ value: String) -> String {
        value.data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
