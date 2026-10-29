import Foundation
import LitheCoreContracts

/// Keeps run resources on the workspace's host; cleanup captures the original
/// session so reconnecting the workspace cannot redirect an old run's deletion.
struct MacRemoteBuildStateLocator: BuildSystemStateLocating {
    let local: any BuildSystemStateLocating
    let registry: RemoteWorkspaceRegistry
    let host: any RemoteBuildStateAccess
    var packages: (any RemotePluginPackageDeploying)? = nil

    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL {
        guard !registry.contains(workspaceURL) else { throw CocoaError(.featureUnsupported) }
        return try local.workspaceStateDirectory(pluginID: pluginID, buildSystemID: buildSystemID, workspaceURL: workspaceURL)
    }

    func allocateOutputFile(in directory: URL) throws -> URL {
        try local.allocateOutputFile(in: directory)
    }

    func removeOutputFile(_ url: URL) { local.removeOutputFile(url) }

    func prepareRun(pluginID: String, buildSystemID: String, packageURL: URL?,
                    workspaceURL: URL, allocatesOutputFile: Bool) async throws -> BuildSystemRunResources {
        guard let resolved = registry.resolve(workspaceURL) else {
            return try await local.prepareRun(pluginID: pluginID, buildSystemID: buildSystemID, packageURL: packageURL,
                                              workspaceURL: workspaceURL, allocatesOutputFile: allocatesOutputFile)
        }
        try Task.checkCancellation()
        let session = resolved.binding.sessionID
        let deployed: RemoteDeployedPluginPackage?
        if let packageURL, let packages,
           try packages.buildRequiresPackage(pluginID: pluginID, buildSystemID: buildSystemID, packageURL: packageURL) {
            deployed = try await packages.deploy(pluginID: pluginID, packageURL: packageURL, session: session)
        } else { deployed = nil }
        let directory: String
        do {
            try Task.checkCancellation()
            guard registry.binding(forRoot: resolved.binding.root)?.sessionID == session else { throw CancellationError() }
            directory = try await Self.worker {
                try host.prepareBuildState(pluginID: pluginID, buildSystemID: buildSystemID,
                                           workspacePath: resolved.remotePath, session: session)
            }
            try Task.checkCancellation()
            guard directory.hasPrefix("/"), !directory.contains("\0") else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            await deployed?.release()
            throw error
        }
        let state = URL(fileURLWithPath: directory, isDirectory: true)
        let output = allocatesOutputFile ? state.appendingPathComponent(UUID().uuidString + ".json") : nil
        return BuildSystemRunResources(pluginDirectory: deployed?.packageURL, workspaceStateDirectory: state, outputFile: output) {
            if let output {
                do { try await Self.worker { try host.removeBuildOutputFile(output.path, session: session) } }
                catch { NSLog("Remote build output cleanup failed (%@)", String(describing: type(of: error))) }
            }
            await deployed?.release()
        }
    }

    private static func worker<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
