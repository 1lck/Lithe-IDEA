import CryptoKit
import Foundation

// Note: 远程工作区按根目录路由见 .agents/notes/implemented/architecture/2026-10-24-remote-workspace-routing.md

/// Placeholder roots of remote workspaces:
/// `Application Support/Lithe/RemoteWorkspaces/<connection>/<path hash>/<folder>`.
///
/// Each one is an empty directory owned by Lithe. It gives the workbench a
/// file URL to key windows, sessions and settings on, while every file below
/// it lives on the host. It is never inside the app bundle, so it does not
/// affect code signing or Sparkle deltas; it is kept between launches so
/// per-project state survives, and contains no user data.
enum MacRemoteWorkspaceRoots {
    static func prepare(in applicationSupport: URL, connection: UUID, remotePath: String) throws -> URL {
        let hash = SHA256.hash(data: Data(remotePath.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = (remotePath as NSString).lastPathComponent
        // "." and ".." would collapse the placeholder onto its parent when
        // the URL is standardized.
        let folder = name.isEmpty || name == "/" || name == "." || name == ".." ? "root" : name
        let root = applicationSupport
            .appendingPathComponent("Lithe/RemoteWorkspaces", isDirectory: true)
            .appendingPathComponent(connection.uuidString, isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }
}
