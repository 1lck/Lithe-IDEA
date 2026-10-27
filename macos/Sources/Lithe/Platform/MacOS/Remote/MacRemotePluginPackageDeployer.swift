import CryptoKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning

/// Deploys a fresh private snapshot of an approved package for one execution.
/// The host receives files only: no package manager, Core or archive extractor
/// is added to the small daemon. The caller owns the returned release action.
struct MacRemotePluginPackageDeployer: RemotePluginPackageDeploying {
    let installed: [InstalledPluginPackage]
    let makeStore: @Sendable (String) -> MacPluginPackageStore
    let evaluator: any PluginMarketplaceEvaluating
    let transport: any MacPluginMarketplaceTransport
    let host: any RemotePluginFileAccess
    let temporaryDirectory: URL

    func buildRequiresPackage(pluginID: String, buildSystemID: String, packageURL: URL) throws -> Bool {
        guard let original = installed.first(where: {
            $0.descriptor.id.rawValue == pluginID && $0.packageURL.standardizedFileURL == packageURL.standardizedFileURL
        }), let manifest = try JSONSerialization.jsonObject(with: original.descriptor.normalizedManifest) as? [String: Any],
           let builds = manifest["buildSystems"] as? [[String: Any]],
           let build = builds.first(where: { $0["id"] as? String == buildSystemID }) else {
            throw failure("plugin.remote.unapproved", L10n.string("The remote plugin package is not part of the approved installation."))
        }
        func referencesPackage(_ value: Any) -> Bool {
            if let text = value as? String { return text.contains("${pluginDir}") }
            if let values = value as? [Any] { return values.contains(where: referencesPackage) }
            if let object = value as? [String: Any] { return object.values.contains(where: referencesPackage) }
            return false
        }
        return referencesPackage(build)
    }

    func deploy(pluginID: String, packageURL: URL, session: String) async throws -> RemoteDeployedPluginPackage {
        guard let original = installed.first(where: {
            $0.descriptor.id.rawValue == pluginID && $0.packageURL.standardizedFileURL == packageURL.standardizedFileURL
        }) else { throw failure("plugin.remote.unapproved", L10n.string("The remote plugin package is not part of the approved installation.")) }
        let facts = try await host.pluginHost(session: session)
        guard let platform = facts.platform, facts.features.contains("upload"), facts.features.contains("runDirectories") else {
            throw failure("plugin.remote.unsupported", L10n.string("This host cannot receive a compatible plugin package. Update the remote server."))
        }
        // Revalidate the original approval before using its source or programs.
        _ = try await worker {
            try makeStore(MacPluginLanguageServerLaunchResolver.hostArchitecture).verifyCandidatePackage(
                at: packageURL, origin: original.installation.origin,
                marketplace: original.installation.marketplace, disk: original.installation.disk)
        }
        let local: LocalSnapshot
        if platform == MacPluginMarketplaceService.currentPlatform {
            local = try await snapshot(original, packageURL: packageURL, architecture: facts.templateArchitecture)
        } else {
            guard let provenance = original.installation.marketplace,
                  let indexURL = URL(string: try evaluator.resolveSource(provenance.repository).indexURL) else {
                throw incompatible(pluginID, platform)
            }
            let kind: PluginMarketplaceSourceKind = original.installation.origin == .community ? .thirdParty : .official
            let indexData = try await transport.data(from: indexURL, maximumBytes: 5 * 1_048_576)
            let index = try evaluator.validateIndex(indexData, sourceKind: kind, platform: platform)
            guard let entry = index.plugins.first(where: { $0.id == pluginID && $0.repository == provenance.repository }),
                  let download = entry.availability.download,
                  download.version == original.manifest.version.description,
                  let url = URL(string: download.downloadURL) else { throw incompatible(pluginID, platform) }
            let downloaded = try await worker {
                try await MacPluginPackageDownloader(transport: transport, temporaryDirectory: temporaryDirectory).download(
                    archiveURL: url, expectedSHA256: download.sha256, pluginID: original.descriptor.id)
            }
            do {
                local = try await worker {
                    let store = makeStore(facts.templateArchitecture)
                    let descriptor = try store.inspectPackage(at: downloaded.packageURL)
                    let review = try evaluator.installReview(manifest: descriptor.normalizedManifest, expectedID: pluginID,
                        expectedVersion: original.manifest.version.description,
                        approvedPrograms: try provenance.approvedPrograms.map { try PluginProgram(canonicalJSON: $0) })
                    // A target variant must not acquire unapproved permissions or
                    // change the declaration consumed by the current module graph.
                    guard review.newPrograms.isEmpty,
                          descriptor.normalizedManifest == original.descriptor.normalizedManifest else {
                        throw failure("plugin.remote.approvalRequired", L10n.string("The remote plugin package changes approved commands or permissions. Install and approve that version first."))
                    }
                    let remoteProvenance = PluginMarketplaceProvenance(sourceID: provenance.sourceID,
                        sourceName: provenance.sourceName, repository: provenance.repository,
                        archiveSHA256: download.sha256,
                        contentDigest: try PluginPackageSignature.contentDigest(packageAt: downloaded.packageURL),
                        approvedPrograms: provenance.approvedPrograms)
                    _ = try store.verifyCandidatePackage(at: downloaded.packageURL, origin: original.installation.origin,
                                                         marketplace: remoteProvenance)
                    let snapshot = try LocalSnapshot.read(at: downloaded.packageURL, descriptor: descriptor)
                    _ = try store.verifyCandidatePackage(at: downloaded.packageURL, origin: original.installation.origin,
                                                         marketplace: remoteProvenance)
                    return snapshot
                }
            } catch {
                await removeLocal(downloaded.temporaryDirectory)
                throw error
            }
            // Files are streamed from this extraction tree below. Its release
            // must occur only after the last upload or an upload failure.
            return try await transfer(local, session: session, facts: facts,
                                      localCleanup: downloaded.temporaryDirectory)
        }
        return try await transfer(local, session: session, facts: facts, localCleanup: nil)
    }

    private func snapshot(_ original: InstalledPluginPackage, packageURL: URL, architecture: String) async throws -> LocalSnapshot {
        try await worker {
            let store = makeStore(architecture)
            let descriptor = try store.verifyCandidatePackage(at: packageURL,
                origin: original.installation.origin, marketplace: original.installation.marketplace, disk: original.installation.disk)
            let snapshot = try LocalSnapshot.read(at: packageURL, descriptor: descriptor)
            _ = try store.verifyCandidatePackage(at: packageURL, origin: original.installation.origin,
                                                 marketplace: original.installation.marketplace, disk: original.installation.disk)
            return snapshot
        }
    }

    private func transfer(_ snapshot: LocalSnapshot, session: String, facts: RemotePluginHost,
                          localCleanup: URL?) async throws -> RemoteDeployedPluginPackage {
        let directoryID = UUID().uuidString
        do {
            // Know the identity before allocation: a lost response or cancelled
            // transfer must still release the exact session-owned directory.
            let allocated = try await host.pluginRequest("fs.createRunDirectory", params: .object([
                "directoryId": .string(directoryID)]), session: session)
            guard case .object(let value) = allocated, case .string(let root) = value["path"],
                  root.hasPrefix("/"), !root.contains("\0"),
                  URL(fileURLWithPath: root).standardizedFileURL.path == root else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let package = root + "/package"
            _ = try await host.pluginRequest("fs.createDir", params: .object(["path": .string(package), "mode": .integer(0o700)]), session: session)
            for entry in snapshot.entries {
                try Task.checkCancellation()
                let target = package + "/" + entry.path
                if entry.directory {
                    _ = try await host.pluginRequest("fs.createDir", params: .object(["path": .string(target), "mode": .integer(0o700)]), session: session)
                } else {
                    try await host.uploadPluginFile(snapshot.root.appendingPathComponent(entry.path), to: target,
                        sha256: entry.sha256, mode: entry.executable ? 0o500 : 0o400, session: session)
                }
            }
            // Detect package replacement or mutation during transfer, including
            // mode changes not covered by the publisher's content signature.
            let after = try await worker { try LocalSnapshot.read(at: snapshot.root, descriptor: snapshot.descriptor) }
            guard snapshot.entries == after.entries else { throw CocoaError(.fileReadCorruptFile) }
            if let localCleanup { await removeLocal(localCleanup) }
            return RemoteDeployedPluginPackage(packageURL: URL(fileURLWithPath: package, isDirectory: true),
                manifest: snapshot.descriptor.normalizedManifest, architecture: facts.templateArchitecture) {
                await release(directoryID, session: session)
            }
        } catch {
            await release(directoryID, session: session)
            if let localCleanup { await removeLocal(localCleanup) }
            throw error
        }
    }

    private func release(_ directoryID: String, session: String) async {
        // A cancelled build still needs an uncancelled cleanup operation on its
        // original host. Directories stay private and owner-writable for removal;
        // runtime state is always outside this snapshot and files are read-only.
        let cleanup = Task.detached {
            do {
                do {
                    _ = try await host.pluginRequest("fs.releaseRunDirectory", params: .object(["directoryId": .string(directoryID)]), session: session)
                } catch let error as RemoteProbeFailure where error.code == "workspace_not_found" {
                    // Cancellation may have won before the allocation.
                }
            } catch { NSLog("Remote plugin snapshot cleanup failed (%@)", String(describing: type(of: error))) }
        }
        await cleanup.value
    }

    private func removeLocal(_ directory: URL) async {
        await Task.detached {
            do { try FileManager().removeItem(at: directory) }
            catch { NSLog("Remote plugin extraction cleanup failed (%@)", String(describing: type(of: error))) }
        }.value
    }

    private func worker<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func failure(_ code: String, _ message: String) -> DeclarativePluginRejection {
        DeclarativePluginRejection(code: code, message: message)
    }

    private func incompatible(_ id: String, _ platform: String) -> DeclarativePluginRejection {
        failure("plugin.remote.platformUnavailable", L10n.string("Plugin \(id) has no approved package for \(platform). Install a compatible plugin version."))
    }
}

private struct LocalSnapshot: Sendable {
    struct Entry: Equatable, Sendable {
        let path: String
        let directory: Bool
        let executable: Bool
        let sha256: String
    }
    let root: URL
    let descriptor: DeclarativePluginDescriptor
    let entries: [Entry]

    static func read(at root: URL, descriptor: DeclarativePluginDescriptor) throws -> Self {
        let manager = FileManager()
        let root = root.standardizedFileURL
        var entries: [Entry] = []
        var total: Int64 = 0
        func visit(_ directory: URL, relative: String) throws {
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                guard entries.count < 50_000 else { throw CocoaError(.fileReadTooLarge) }
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                // Directory enumeration may canonicalize /var to /private/var.
                // Build relative names from components, never string offsets.
                let path = relative + url.lastPathComponent
                guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 4096 else { throw CocoaError(.fileReadInvalidFileName) }
                total += Int64(values.fileSize ?? 0)
                guard total <= 2 * 1024 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let directory = values.isDirectory == true
                entries.append(Entry(path: path, directory: directory, executable: !directory && manager.isExecutableFile(atPath: url.path),
                    sha256: directory ? "" : try MacPluginPackageDownloader.sha256(of: url)))
                if directory { try visit(url, relative: path + "/") }
            }
        }
        try visit(root, relative: "")
        return Self(root: root, descriptor: descriptor, entries: entries)
    }
}
