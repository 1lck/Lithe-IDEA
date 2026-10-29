import CryptoKit
import Foundation
import LithePluginPackageSigning
import Testing

/// Cross-platform acceptance for the package signature: the same fixed
/// vectors answer identically on Swift/CryptoKit and the Windows Rust host.
/// The vectors live in
/// `shared/contracts/plugins/v1/fixtures/signature-vectors.json` and anchor
/// the Ed25519 primitive to the public RFC 8032 test key, so neither
/// platform's own round-trip can drift.
struct PluginSignatureVectorTests {
    private struct Fixture: Codable {
        struct Ed25519: Codable {
            let seedHex: String
            let publicKeyHex: String
            let messageEmptySignatureHex: String
        }
        struct CanonicalPayload: Codable {
            let keyID: String
            let pluginID: String
            let pluginVersion: String
            let files: [String: String]
            let payloadBase64: String
            let signatureBase64: String
        }
        struct ContentDigest: Codable {
            let files: [String: String]
            let digest: String
        }

        let ed25519: Ed25519
        let packageFiles: [String: String]
        let canonicalPayload: CanonicalPayload
        let contentDigest: ContentDigest
    }

    private static func fixture() throws -> Fixture {
        let url = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/signature-vectors.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func privateKey(from fixture: Fixture) throws -> Curve25519.Signing.PrivateKey {
        var seed = Data()
        var index = fixture.ed25519.seedHex.startIndex
        while index < fixture.ed25519.seedHex.endIndex {
            let next = fixture.ed25519.seedHex.index(index, offsetBy: 2)
            seed.append(UInt8(fixture.ed25519.seedHex[index..<next], radix: 16)!)
            index = next
        }
        return try #require(try? Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    @Test
    func primitiveMatchesTheRFC8032Anchor() throws {
        let fixture = try Self.fixture()
        let privateKey = try Self.privateKey(from: fixture)
        let publicKey = try #require(
            try? Curve25519.Signing.PublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)
        )
        #expect(Data(publicKey.rawRepresentation).hex == fixture.ed25519.publicKeyHex)
        let signature = try privateKey.signature(for: Data())
        #expect(signature.hex == fixture.ed25519.messageEmptySignatureHex)
    }

    /// Signing the fixed package bytes with the shared test seed reproduces
    /// the recorded signature byte for byte: the canonical payload, the path
    /// sorting, and the token encoding are identical across platforms.
    @Test
    func deterministicSignatureReproducesTheSharedVector() throws {
        let fixture = try Self.fixture()
        let privateKey = try Self.privateKey(from: fixture)
        let root = try makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = try PluginPackageSignature.makeDocument(
            packageAt: root,
            pluginID: fixture.canonicalPayload.pluginID,
            pluginVersion: fixture.canonicalPayload.pluginVersion,
            privateKey: privateKey,
            keyID: fixture.canonicalPayload.keyID
        )
        #expect(document.files == fixture.canonicalPayload.files)
        #expect(document.signature == fixture.canonicalPayload.signatureBase64)

        // The recorded signature verifies with the derived public key.
        let publicKey = try #require(
            try? Curve25519.Signing.PublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)
        )
        try PluginPackageSignature.verify(
            packageAt: root,
            pluginID: fixture.canonicalPayload.pluginID,
            pluginVersion: fixture.canonicalPayload.pluginVersion,
            document: document,
            publicKey: publicKey
        )
    }

    /// The content digest over the fixed package matches the shared answer,
    /// including the non-ASCII file names.
    @Test
    func contentDigestMatchesTheSharedVector() throws {
        let fixture = try Self.fixture()
        let root = try makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }

        let digest = try PluginPackageSignature.contentDigest(packageAt: root)
        #expect(digest == fixture.contentDigest.digest)
    }

    /// The signature document of the shared vector also verifies after a
    /// write/read round trip through the on-disk format.
    @Test
    func recordedDocumentVerifiesAfterWriteAndRead() throws {
        let fixture = try Self.fixture()
        let privateKey = try Self.privateKey(from: fixture)
        let root = try makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }

        var files: [String: String] = [:]
        for (path, digest) in fixture.canonicalPayload.files {
            files[path] = digest
        }
        let document = PluginPackageSignature.Document(
            keyID: fixture.canonicalPayload.keyID,
            pluginID: fixture.canonicalPayload.pluginID,
            pluginVersion: fixture.canonicalPayload.pluginVersion,
            files: files,
            signature: fixture.canonicalPayload.signatureBase64
        )
        try PluginPackageSignature.write(document, to: root)
        let read = try PluginPackageSignature.read(from: root)
        try PluginPackageSignature.verify(
            packageAt: root,
            pluginID: fixture.canonicalPayload.pluginID,
            pluginVersion: fixture.canonicalPayload.pluginVersion,
            document: read,
            trustedKeys: [
                fixture.canonicalPayload.keyID: privateKey.publicKey
            ]
        )

        // Any changed file is rejected with the same digest mismatch the
        // Windows host reports.
        try Data("changed".utf8).write(to: root.appendingPathComponent("plugin.json"))
        #expect(throws: PluginPackageSignature.Error.self) {
            try PluginPackageSignature.verify(
                packageAt: root,
                pluginID: fixture.canonicalPayload.pluginID,
                pluginVersion: fixture.canonicalPayload.pluginVersion,
                document: read,
                trustedKeys: [
                    fixture.canonicalPayload.keyID: privateKey.publicKey
                ]
            )
        }
    }

    /// Materializes the fixture's package tree with its UTF-8 file contents.
    private func makePackage(_ fixture: Fixture) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-signature-vector-\(UUID().uuidString)", isDirectory: true)
        for (relativePath, content) in fixture.packageFiles {
            let target = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: target)
        }
        return root
    }
}

extension Data {
    fileprivate var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
