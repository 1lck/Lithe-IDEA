import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A workspace-owned host snapshot. UI accessors never perform network I/O or
/// inspect this Mac; only `probeHost` runs host probes on the service's worker.
final class MacRemoteRuntimeLocator: RuntimeLocator, RuntimeToolDiscovery, @unchecked Sendable {
    private struct Snapshot {
        var environment: [String: String] = [:]
        var executables: Set<String> = []
        var failure: String?
    }
    private let binding: RemoteWorkspaceBinding
    private let host: any RemoteRuntimeProbing
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var generation: UInt64 = 0

    init(binding: RemoteWorkspaceBinding, host: any RemoteRuntimeProbing) {
        self.binding = binding
        self.host = host
    }

    var discoveryFailure: String? { lock.withLock { snapshot.failure } }
    func environment() -> [String: String] { lock.withLock { snapshot.environment } }
    func invalidateProbeCache() { lock.withLock { generation &+= 1; snapshot = Snapshot() } }

    func normalizedPath(_ path: String, relativeTo root: URL?) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" || value.hasPrefix("~/") {
            guard let home = environment()["HOME"], home.hasPrefix("/") else { return value }
            value = home + value.dropFirst()
        }
        if !value.hasPrefix("/"), let root { value = root.appendingPathComponent(value).path }
        let local = binding.root.path
        if value == local { value = binding.remoteRoot }
        else if value.hasPrefix(local + "/") { value = binding.remoteRoot + value.dropFirst(local.count) }
        // NSString.standardizingPath expands ~ with the local account; only
        // absolute host paths may reach Foundation's normalization here.
        return value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL.path : value
    }

    func probeHost(isCancelled: @Sendable () -> Bool) {
        let ticket = lock.withLock { () -> UInt64 in
            generation &+= 1
            return generation
        }
        var next = Snapshot()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        func check() throws {
            if isCancelled() || lock.withLock({ generation != ticket }) { throw CancellationError() }
            if ContinuousClock.now >= deadline { throw ProbeError.deadline }
        }
        func optional<Value>(_ operation: () throws -> Value) throws -> Value? {
            try check()
            do { return try operation() }
            // log-exempt: 预期的缺失：探测的可选文件或目录不存在，按未发现处理
            catch let error as RustCoreBridge.CoreCallError
                where error.code == "workspace_not_found" || error.details?.contains("NOT_A_DIRECTORY") == true { return nil }
            // log-exempt: 预期的缺失：探测的可选文件或目录不存在，按未发现处理
            catch let error as RemoteProbeFailure where error.code == "not_found" { return nil }
        }
        func executable(_ path: String) throws -> Bool {
            let found = try optional { try host.runtimeExecutable(path, session: binding.sessionID) } ?? false
            if found { next.executables.insert(path) }
            return found
        }
        func entries(_ path: String) throws -> [RemoteDirectoryEntry] {
            let values = try optional { try host.runtimeDirectory(path, session: binding.sessionID) } ?? []
            guard values.count <= 16_384 else { throw ProbeError.limit }
            return values
        }
        do {
            try check()
            next.environment = try host.runtimeEnvironment(session: binding.sessionID)
            // Login PATH already includes the host's configured version managers.
            let searchPath = (next.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            guard searchPath.count <= 64 else { throw ProbeError.limit }
            for directory in searchPath {
                for entry in try entries(directory) where entry.metadata.kind == "file" || entry.metadata.kind == "symlink" {
                    let path = directory + "/" + entry.name
                    if entry.metadata.kind == "symlink" {
                        guard entry.metadata.symlinkTargetKind == "file" else { continue }
                        if let mode = entry.metadata.symlinkTargetMode {
                            guard mode & 0o111 != 0 else { continue }
                        } else if !(try executable(path)) { continue }
                    } else if let mode = entry.metadata.mode {
                        guard mode & 0o111 != 0 else { continue }
                    } else if !(try executable(path)) { continue }
                    next.executables.insert(path)
                    guard next.executables.count <= 65_536 else { throw ProbeError.limit }
                }
            }
        // log-exempt: 用户取消：调用方取消远程运行时发现
        } catch is CancellationError { return }
        catch {
            // A failed/incomplete host snapshot must never authorize a launch.
            next = Snapshot()
            next.failure = L10n.string("Could not discover runtimes on the remote host. Check the connection and refresh.")
        }
        guard !isCancelled() else { return }
        lock.withLock {
            guard generation == ticket else { return }
            snapshot = next
        }
    }

    private enum ProbeError: Error { case deadline, limit }
    func isExecutable(at url: URL) -> Bool { lock.withLock { snapshot.executables.contains(normalizedPathWithoutLock(url.path)) } }
    private func normalizedPathWithoutLock(_ path: String) -> String {
        let root = binding.root.path
        return path == root ? binding.remoteRoot : path.hasPrefix(root + "/") ? binding.remoteRoot + path.dropFirst(root.count) : path
    }
    func candidates(for command: String, projectURL: URL?, environment: [String: String]) -> [RuntimeToolCandidate] {
        guard !command.isEmpty, !command.contains("/") else { return [] }
        return (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(command) }
            .filter { isExecutable(at: $0) }.map { RuntimeToolCandidate(command: command, executableURL: $0, source: .path, detail: nil) }
    }
    func guidance(for command: String, projectURL: URL?, environment: [String: String]) -> RuntimeToolGuidance {
        RuntimeToolGuidance(command: command,
            summary: L10n.string("The required tool is not available on the remote host."),
            recovery: L10n.string("Install the tool on the remote host, add it to the login PATH, and refresh the available runtimes."))
    }
}
