import CryptoKit
import Foundation

/// Signs and verifies the complete file tree of an official native plugin package.
///
/// The package signature authenticates the release artifact independently from
/// Apple's code-signing identity. Native bundle validation remains required so
/// malformed or unsigned bundles cannot be loaded.
public enum PluginPackageSignature {
    public static let schemaVersion = 1
    public static let algorithm = "ed25519"
    /// Key ID used for newly signed official packages.
    public static let keyID = "lithe-official-plugins-v2"
    /// Base64-encoded public key for `keyID`.
    public static let publisherPublicKeyBase64 = "yTjUaLpCNXXEQDuan5Ymw5rCtR0JeTNmh6hyTfOFjTs="
    /// Every publisher key the host trusts, keyed by key ID. Rotation adds a
    /// new ID here before release workflows sign with it; a key ID must never
    /// be reused for different public-key bytes.
    public static let trustedPublisherKeysBase64: [String: String] = [
        keyID: publisherPublicKeyBase64
    ]
    public static let signatureFileName = "lithe-plugin-signature.json"

    public struct Document: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let algorithm: String
        public let keyID: String
        public let pluginID: String
        public let pluginVersion: String
        public let files: [String: String]
        public let signature: String

        public init(
            schemaVersion: Int = PluginPackageSignature.schemaVersion,
            algorithm: String = PluginPackageSignature.algorithm,
            keyID: String = PluginPackageSignature.keyID,
            pluginID: String,
            pluginVersion: String,
            files: [String: String],
            signature: String
        ) {
            self.schemaVersion = schemaVersion
            self.algorithm = algorithm
            self.keyID = keyID
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
        case untrustedKey(String)

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
            case .untrustedKey(let keyID):
                return "The plugin package is signed by key \(keyID), which this version of Lithe does not trust."
            }
        }
    }

    public static func makeDocument(
        packageAt packageURL: URL,
        pluginID: String,
        pluginVersion: String,
        privateKey: Curve25519.Signing.PrivateKey,
        keyID: String = PluginPackageSignature.keyID,
        fileManager: FileManager = .default
    ) throws -> Document {
        guard isValidKeyID(keyID) else { throw Error.invalidDocument }
        let files = try fileDigests(
            packageAt: packageURL,
            fileManager: fileManager
        )
        let payload = canonicalPayload(
            keyID: keyID,
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            files: files
        )
        return Document(
            keyID: keyID,
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            files: files,
            signature: try privateKey.signature(for: payload).base64EncodedString()
        )
    }

    /// Decodes `trustedPublisherKeysBase64`; an invalid embedded key is a
    /// build defect and is reported instead of being silently skipped.
    public static func trustedPublisherKeys() throws -> [String: Curve25519.Signing.PublicKey] {
        try trustedPublisherKeysBase64.mapValues { encoded in
            guard let data = Data(base64Encoded: encoded),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
                throw Error.publicKeyUnavailable
            }
            return key
        }
    }

    /// Selects the trusted key named by the document, then verifies with it.
    public static func verify(
        packageAt packageURL: URL,
        pluginID: String,
        pluginVersion: String,
        document: Document,
        trustedKeys: [String: Curve25519.Signing.PublicKey],
        fileManager: FileManager = .default
    ) throws {
        guard let publicKey = trustedKeys[document.keyID] else {
            throw Error.untrustedKey(document.keyID)
        }
        try verify(
            packageAt: packageURL,
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            document: document,
            publicKey: publicKey,
            fileManager: fileManager
        )
    }

    public static func verify(
        packageAt packageURL: URL,
        pluginID: String,
        pluginVersion: String,
        document: Document,
        publicKey: Curve25519.Signing.PublicKey,
        fileManager: FileManager = .default
    ) throws {
        guard document.schemaVersion == schemaVersion,
              document.algorithm == algorithm,
              isValidKeyID(document.keyID),
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
            keyID: document.keyID,
            pluginID: document.pluginID,
            pluginVersion: document.pluginVersion,
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

    /// SHA-256 over the sorted path and digest of every package file. Hosts
    /// record it when installing a package that carries no publisher
    /// signature and recheck it on every load, so a changed or added file is
    /// detected. Symbolic links and unsafe paths are refused as for signing.
    public static func contentDigest(
        packageAt packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let digests = try fileDigests(packageAt: packageURL, fileManager: fileManager)
        let lines = digests.keys.sorted().map { path in "\(token(path))=\(digests[path]!)\n" }
        return SHA256.hash(data: Data(lines.joined().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    /// Key IDs are written raw into the signed payload to keep existing
    /// signatures byte-compatible, so they are restricted to a safe alphabet.
    public static func isValidKeyID(_ keyID: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        return !keyID.isEmpty && keyID.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func canonicalPayload(
        keyID: String,
        pluginID: String,
        pluginVersion: String,
        files: [String: String]
    ) -> Data {
        var lines = [
            "schemaVersion=\(schemaVersion)",
            "algorithm=\(algorithm)",
            "keyID=\(keyID)",
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
