import CryptoKit
import Foundation
import LithePluginPackageSigning
import Testing

struct PluginPackageSignatureTests {
    @Test
    func signatureCoversEveryPackageFile() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateKey = try #require(
            try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        )
        let document = try PluginPackageSignature.makeDocument(
            packageAt: root,
            pluginID: "dev.example.plugin",
            pluginVersion: "0.3.0",
            privateKey: privateKey
        )
        try PluginPackageSignature.write(document, to: root)

        try PluginPackageSignature.verify(
            packageAt: root,
            pluginID: "dev.example.plugin",
            pluginVersion: "0.3.0",
            document: document,
            publicKey: privateKey.publicKey
        )
    }

    @Test
    func tamperingWithAPluginFileIsRejected() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateKey = try #require(
            try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        )
        let document = try PluginPackageSignature.makeDocument(
            packageAt: root,
            pluginID: "dev.example.plugin",
            pluginVersion: "0.3.0",
            privateKey: privateKey
        )
        try PluginPackageSignature.write(document, to: root)
        try Data("changed".utf8).write(
            to: root.appendingPathComponent("Example.bundle/Contents/MacOS/plugin")
        )

        #expect(throws: PluginPackageSignature.Error.fileDigestMismatch(
            "Example.bundle/Contents/MacOS/plugin"
        )) {
            try PluginPackageSignature.verify(
                packageAt: root,
                pluginID: "dev.example.plugin",
                pluginVersion: "0.3.0",
                document: document,
                publicKey: privateKey.publicKey
            )
        }
    }

    @Test
    func addingAFileAfterSigningIsRejected() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateKey = try #require(
            try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        )
        let document = try PluginPackageSignature.makeDocument(
            packageAt: root,
            pluginID: "dev.example.plugin",
            pluginVersion: "0.3.0",
            privateKey: privateKey
        )
        try PluginPackageSignature.write(document, to: root)
        try Data("unexpected".utf8).write(to: root.appendingPathComponent("unexpected.txt"))

        #expect(throws: PluginPackageSignature.Error.fileListMismatch) {
            try PluginPackageSignature.verify(
                packageAt: root,
                pluginID: "dev.example.plugin",
                pluginVersion: "0.3.0",
                document: document,
                publicKey: privateKey.publicKey
            )
        }
    }

    @Test
    func trustedKeysSelectTheKeyNamedByTheDocument() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let nextKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        let trustedKeys = [
            "example-current": currentKey.publicKey,
            "example-next": nextKey.publicKey
        ]

        for (keyID, privateKey) in [("example-current", currentKey), ("example-next", nextKey)] {
            let document = try PluginPackageSignature.makeDocument(
                packageAt: root,
                pluginID: "dev.example.plugin",
                pluginVersion: "0.3.0",
                privateKey: privateKey,
                keyID: keyID
            )
            #expect(document.keyID == keyID)
            try PluginPackageSignature.verify(
                packageAt: root,
                pluginID: "dev.example.plugin",
                pluginVersion: "0.3.0",
                document: document,
                trustedKeys: trustedKeys
            )
        }
    }

    @Test
    func documentRelabelledWithAnotherTrustedKeyIDIsRejected() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let nextKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        let signed = try PluginPackageSignature.makeDocument(
            packageAt: root,
            pluginID: "dev.example.plugin",
            pluginVersion: "0.3.0",
            privateKey: currentKey,
            keyID: "example-current"
        )
        let relabelled = PluginPackageSignature.Document(
            keyID: "example-next",
            pluginID: signed.pluginID,
            pluginVersion: signed.pluginVersion,
            files: signed.files,
            signature: signed.signature
        )

        #expect(throws: PluginPackageSignature.Error.invalidSignature) {
            try PluginPackageSignature.verify(
                packageAt: root,
                pluginID: "dev.example.plugin",
                pluginVersion: "0.3.0",
                document: relabelled,
                trustedKeys: ["example-current": currentKey.publicKey, "example-next": nextKey.publicKey]
            )
        }
        #expect(throws: PluginPackageSignature.Error.untrustedKey("example-unknown")) {
            try PluginPackageSignature.verify(
                packageAt: root,
                pluginID: "dev.example.plugin",
                pluginVersion: "0.3.0",
                document: PluginPackageSignature.Document(
                    keyID: "example-unknown",
                    pluginID: signed.pluginID,
                    pluginVersion: signed.pluginVersion,
                    files: signed.files,
                    signature: signed.signature
                ),
                trustedKeys: ["example-current": currentKey.publicKey]
            )
        }
    }

    @Test
    func embeddedTrustedKeysIncludeTheCurrentSigningKey() throws {
        let trustedKeys = try PluginPackageSignature.trustedPublisherKeys()

        #expect(trustedKeys[PluginPackageSignature.keyID]?.rawRepresentation.base64EncodedString()
            == PluginPackageSignature.publisherPublicKeyBase64)
        #expect(trustedKeys.keys.allSatisfy(PluginPackageSignature.isValidKeyID))
    }

    private func makePackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-signature-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("Example.bundle/Contents/MacOS/plugin")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("manifest".utf8).write(to: root.appendingPathComponent("plugin.json"))
        try Data("binary".utf8).write(to: executable)
        return root
    }
}
