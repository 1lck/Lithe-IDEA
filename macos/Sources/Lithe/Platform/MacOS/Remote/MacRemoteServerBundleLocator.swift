import Foundation

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// Finds the remote workspace servers packaged in
/// `Contents/Resources/RemoteServers` by `scripts/build-remote-servers.sh`.
/// The directory is part of the signed, Sparkle-updated bundle: it is only
/// read, and the binaries are streamed to hosts from it unchanged.
enum MacRemoteServerBundleLocator {
    static let directoryName = "RemoteServers"
    static let executableName = "lithe-remote-server"

    /// `nil` when the app was started without packaged servers, for example
    /// from `swift run`; remote connections then stay unavailable.
    static func locate(resources: URL? = Bundle.main.resourceURL) -> RemoteServerBundle? {
        guard let root = resources?.appendingPathComponent(directoryName, isDirectory: true) else { return nil }
        struct Manifest: Decodable { let serverVersion: String }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let targets = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let builds = targets.sorted().compactMap { target -> RemoteServerBuild? in
            let executable = root.appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent(executableName)
            guard FileManager.default.fileExists(atPath: executable.path) else { return nil }
            return RemoteServerBuild(target: target, path: executable.path)
        }
        return builds.isEmpty ? nil : RemoteServerBundle(version: manifest.serverVersion, builds: builds)
    }
}
