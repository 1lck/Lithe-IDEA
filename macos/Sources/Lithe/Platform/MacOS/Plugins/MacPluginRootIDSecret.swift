import Foundation
import Security

// Note: rootID 的密钥与生命周期见 .agents/notes/implemented/architecture/2026-10-30-plugin-backend-workspace-context.md

/// The host secret behind the `rootID`s plugin backends see
/// (`PluginWorkspaceRootIDs`).
///
/// It lives in `Application Support/Lithe/PluginHost/root-id.key`. That is a
/// platform-writable directory, outside the app bundle (so it never touches
/// code signing or Sparkle deltas) and outside every plugin's `${stateDir}`.
/// It is created on first use with mode 0600 and never rewritten; deleting
/// it only gives every folder new root IDs. Backends run as the user, so
/// the secret keeps root IDs from being computed from a guessed path or
/// matched between plugins through the protocol, not from a process that
/// reads the user's files.
enum MacPluginRootIDSecret {
    static let byteCount = 32

    static func fileURL(fileStorage: any FileStorage) -> URL {
        fileStorage.applicationSupportDirectory()
            .appendingPathComponent("Lithe/PluginHost", isDirectory: true)
            .appendingPathComponent("root-id.key", isDirectory: false)
    }

    /// The stored secret, created when missing. Another window creating it
    /// at the same moment wins and both read the same bytes. When the
    /// directory cannot be written, a secret for this launch is used: root
    /// IDs stay unique, only not stable across launches.
    static func load(from url: URL, fileManager: FileManager = .default) -> Data {
        if let stored = read(url) { return stored }
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        if status != errSecSuccess {
            bytes = Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) })
        }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return read(url) ?? bytes }
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, byteCount) }
        close(descriptor)
        guard written == byteCount else {
            try? fileManager.removeItem(at: url)
            return bytes
        }
        return bytes
    }

    private static func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count == byteCount else { return nil }
        return data
    }
}
