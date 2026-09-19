import CryptoKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// Resolves only managed application resources; a user's PATH is never a Node fallback.
/// Note: .agents/notes/proposed/architecture/2026-09-19-vscode-extension-host.md
struct MacExtensionHostResources {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let nodePaths: [String: String]
        let entrypoint: String
        let extensionPaths: [String]
    }

    private let resourceRoot: URL?
    private let storageRoot: URL
    private let architecture: String
    private let fileManager: FileManager

    init(
        resourceRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("ExtensionHost", isDirectory: true),
        storageRoot: URL,
        architecture: String = Self.nativeArchitecture,
        fileManager: FileManager = .default
    ) {
        self.resourceRoot = resourceRoot
        self.storageRoot = storageRoot
        self.architecture = architecture
        self.fileManager = fileManager
    }

    static var nativeArchitecture: String {
        #if arch(arm64)
        "darwin-arm64"
        #else
        "darwin-x64"
        #endif
    }

    func startup(
        workspace: URL,
        environment: [String: String],
        configuration: ToolingJSONValue = .object([:]),
        workspaceTrusted: Bool = false
    ) throws -> ExtensionHostStartupConfiguration {
        guard workspace.isFileURL,
              (try? workspace.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ExtensionHostFailure("invalidParams", "Open a local workspace before starting the extension host.")
        }
        guard let root = resourceRoot?.standardizedFileURL.resolvingSymlinksInPath() else {
            throw unavailable()
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw unavailable() }
        _ = try resource("manifest.json", in: root, directory: false)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw ExtensionHostFailure("invalidParams", "The bundled extension host manifest is invalid. Reinstall Lithe.") }
        guard manifest.schemaVersion == 1, let nodePath = manifest.nodePaths[architecture],
              !manifest.extensionPaths.isEmpty else { throw unavailable() }
        let node = try resource(nodePath, in: root, directory: false)
        let entrypoint = try resource(manifest.entrypoint, in: root, directory: false)
        guard fileManager.isExecutableFile(atPath: node.path) else { throw unavailable() }
        let extensions = try manifest.extensionPaths.sorted().map { path -> URL in
            let directory = try resource(path, in: root, directory: true)
            _ = try resource(path + "/package.json", in: root, directory: false)
            return directory
        }
        let workspaceURL = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let workspaceKey = SHA256.hash(data: Data(workspaceURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let global = storageRoot.appendingPathComponent("global", isDirectory: true)
        let workspaceStorage = storageRoot.appendingPathComponent("workspaces/" + workspaceKey, isDirectory: true)
        let logs = workspaceStorage.appendingPathComponent("logs", isDirectory: true)
        for directory in [global, workspaceStorage, logs] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var launchEnvironment = environment
        launchEnvironment["PATH"] = [node.deletingLastPathComponent().path, environment["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        return ExtensionHostStartupConfiguration(
            launch: ExtensionHostLaunchConfiguration(node: node, entrypoint: entrypoint,
                workspace: workspaceURL, environment: launchEnvironment),
            initialize: .object([
                "protocolVersion": .integer(1),
                "workspaceFolders": .array([.object([
                    "uri": .string(workspaceURL.absoluteString), "name": .string(workspaceURL.lastPathComponent)
                ])]),
                "extensionPaths": .array(extensions.map { .string($0.path) }),
                "storage": .object([
                    "globalStoragePath": .string(global.path),
                    "workspaceStoragePath": .string(workspaceStorage.path),
                    "logPath": .string(logs.path)
                ]),
                "configuration": configuration,
                "workspaceTrusted": .bool(workspaceTrusted)
            ])
        )
    }

    private func resource(_ path: String, in root: URL, directory: Bool) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ExtensionHostFailure("invalidParams", "Extension host resource paths must stay inside the application bundle.")
        }
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
              directory ? values.isDirectory == true : values.isRegularFile == true else { throw unavailable() }
        return url
    }

    private func unavailable() -> ExtensionHostFailure {
        ExtensionHostFailure("notInitialized", "Managed extension host resources are missing for this build. Install a Lithe build that includes the extension host runtime.")
    }
}
