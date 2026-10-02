import CryptoKit
import Foundation
import LithePluginPackageSigning

@main
struct LithePluginPackageSigner {
    static func main() throws {
        guard CommandLine.arguments.count == 2 ||
            (CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--verify") else {
            throw SignerError.usage
        }
        let isVerification = CommandLine.arguments.count == 3
        let packageURL = URL(
            fileURLWithPath: CommandLine.arguments[isVerification ? 2 : 1],
            isDirectory: true
        )
        let manifest = try loadManifest(from: packageURL)

        if isVerification {
            let document = try PluginPackageSignature.read(from: packageURL)
            guard let publicKeyData = Data(base64Encoded: PluginPackageSignature.publisherPublicKeyBase64),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
                throw SignerError.invalidPublicKey
            }
            try PluginPackageSignature.verify(
                packageAt: packageURL,
                pluginID: manifest.pluginID,
                pluginVersion: manifest.pluginVersion,
                document: document,
                publicKey: publicKey
            )
            writeStatus("Verified publisher signature for \(manifest.pluginID) \(manifest.pluginVersion)")
            return
        }

        let keyText = String(
            data: FileHandle.standardInput.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyText,
              let keyData = Data(base64Encoded: keyText),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
            throw SignerError.invalidPrivateKey
        }
        guard privateKey.publicKey.rawRepresentation.base64EncodedString()
            == PluginPackageSignature.publisherPublicKeyBase64 else {
            throw SignerError.untrustedPrivateKey
        }

        let document = try PluginPackageSignature.makeDocument(
            packageAt: packageURL,
            pluginID: manifest.pluginID,
            pluginVersion: manifest.pluginVersion,
            privateKey: privateKey
        )
        try PluginPackageSignature.write(document, to: packageURL)
        writeStatus("Signed publisher package \(manifest.pluginID) \(manifest.pluginVersion)")
    }

    /// Keep stdout available for machine-readable command results.
    /// Build scripts capture stdout as the package path, so status messages belong on stderr.
    private static func writeStatus(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func loadManifest(from packageURL: URL) throws -> (pluginID: String, pluginVersion: String) {
        let manifestURL = packageURL.appendingPathComponent("plugin.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let pluginID = manifest["id"] as? String,
              let pluginVersion = manifest["version"] as? String,
              !pluginID.isEmpty,
              !pluginVersion.isEmpty else {
            throw SignerError.invalidManifest
        }
        return (pluginID, pluginVersion)
    }
}

private enum SignerError: Error {
    case usage
    case invalidPrivateKey
    case untrustedPrivateKey
    case invalidPublicKey
    case invalidManifest
}
