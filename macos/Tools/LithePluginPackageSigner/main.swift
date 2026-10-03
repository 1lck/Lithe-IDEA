import CryptoKit
import Foundation
import LithePluginPackageSigning

@main
struct LithePluginPackageSigner {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let isVerification = arguments.first == "--verify"
        let offset = isVerification ? 1 : 0
        guard arguments.count == offset + 3,
              arguments[offset] == "--channel",
              let channel = PluginPackageSignature.Channel(rawValue: arguments[offset + 1]) else {
            throw SignerError.usage
        }
        let packageURL = URL(fileURLWithPath: arguments[offset + 2], isDirectory: true)
        let manifest = try loadManifest(from: packageURL)
        let trustedPublicKeyBase64 = try trustedPublicKeyBase64(for: channel)
        guard let publicKeyData = Data(base64Encoded: trustedPublicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw SignerError.invalidPublicKey
        }

        if isVerification {
            let document = try PluginPackageSignature.read(from: packageURL)
            try PluginPackageSignature.verify(
                packageAt: packageURL,
                pluginID: manifest.pluginID,
                pluginVersion: manifest.pluginVersion,
                expectedChannel: channel,
                document: document,
                publicKey: publicKey
            )
            writeStatus("Verified \(channel.rawValue) publisher signature for \(manifest.pluginID) \(manifest.pluginVersion)")
            return
        }

        let keyText = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyText,
              let keyData = Data(base64Encoded: keyText),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
            throw SignerError.invalidPrivateKey
        }
        guard privateKey.publicKey.rawRepresentation.base64EncodedString() == trustedPublicKeyBase64 else {
            throw SignerError.untrustedPrivateKey
        }

        let document = try PluginPackageSignature.makeDocument(
            packageAt: packageURL,
            pluginID: manifest.pluginID,
            pluginVersion: manifest.pluginVersion,
            channel: channel,
            privateKey: privateKey
        )
        try PluginPackageSignature.write(document, to: packageURL)
        writeStatus("Signed \(channel.rawValue) publisher package \(manifest.pluginID) \(manifest.pluginVersion)")
    }

    private static func trustedPublicKeyBase64(for channel: PluginPackageSignature.Channel) throws -> String {
        switch channel {
        case .stable:
            return PluginPackageSignature.stablePublisherPublicKeyBase64
        case .preview:
            let value = ProcessInfo.processInfo.environment["LITHE_PLUGIN_PACKAGE_PUBLIC_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { throw SignerError.missingPreviewPublicKey }
            return value
        }
    }

    private static func writeStatus(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func loadManifest(from packageURL: URL) throws -> (pluginID: String, pluginVersion: String) {
        let manifestURL = packageURL.appendingPathComponent("plugin.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let pluginID = manifest["id"] as? String,
              let pluginVersion = manifest["version"] as? String,
              !pluginID.isEmpty, !pluginVersion.isEmpty else {
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
    case missingPreviewPublicKey
    case invalidManifest
}
