import Foundation
import LitheModuleAPI

/// Discovers executable shells using only the selected host's login environment
/// and filesystem. Directory batches avoid one network round trip per candidate.
enum MacRemoteShellDiscovery {
    static func discover(session: String, host: any RemoteShellProbing) async throws -> [String] {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try availableShells(session: session, host: host, isCancelled: { cancellation.isCancelled })
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    static func availableShells(
        session: String, host: any RemoteShellProbing, isCancelled: () -> Bool
    ) throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(30)
        func check() throws {
            if isCancelled() { throw CancellationError() }
            if ContinuousClock.now >= deadline { throw DiscoveryError.failed }
        }
        do {
            try check()
            let environment = try host.shellEnvironment(session: session)
            try check()
            let registered = try host.registeredShells(session: session)
            let candidates = MacTerminalShellDiscovery.candidates(
                environment: environment, registeredShells: registered, searchDefaults: [])
            guard candidates.count <= 1_024 else { throw DiscoveryError.failed }
            let directories = Set(candidates.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            guard directories.count <= 64 else { throw DiscoveryError.failed }
            var executable = Set<String>()
            for directory in directories.sorted() {
                try check()
                let entries: [RemoteDirectoryEntry]
                do { entries = try host.runtimeDirectory(directory, session: session) }
                catch let error as RustCoreBridge.CoreCallError where error.code == "workspace_not_found" { continue }
                guard entries.count <= 16_384 else { throw DiscoveryError.failed }
                let names = Set(candidates.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == directory }
                    .map { URL(fileURLWithPath: $0).lastPathComponent })
                for entry in entries where names.contains(entry.name) {
                    let path = URL(fileURLWithPath: directory).appendingPathComponent(entry.name).path
                    let metadata = entry.metadata
                    if metadata.kind == "file", let mode = metadata.mode, mode & 0o111 != 0 {
                        executable.insert(path)
                    } else if metadata.kind == "symlink", metadata.symlinkTargetKind == "file" {
                        if let mode = metadata.symlinkTargetMode {
                            if mode & 0o111 != 0 { executable.insert(path) }
                        } else {
                            // Older servers report target kind without permissions.
                            try check()
                            if try host.runtimeExecutable(path, session: session) { executable.insert(path) }
                        }
                    }
                }
            }
            try check()
            return candidates.filter { executable.contains($0) }
        } catch is CancellationError { throw CancellationError() }
        catch { throw DiscoveryError.failed }
    }

    private enum DiscoveryError: LocalizedError {
        case failed
        var errorDescription: String? {
            L10n.string("Could not discover shells on the remote host. Check the connection and try again.")
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
