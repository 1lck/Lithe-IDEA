import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A workspace-owned host snapshot. UI accessors never perform network I/O or
/// inspect this Mac; only discover runs host probes on the service's worker.
final class MacRemoteRuntimeLocator: RuntimeLocator, RuntimeToolDiscovery, @unchecked Sendable {
    private struct Snapshot {
        var environment: [String: String] = [:]
        var executables: Set<String> = []
        var java: [JavaRuntimeCandidate] = []
        var maven: [MavenRuntimeCandidate] = []
        var pathJava: String?
        var failure: String?
        var requirements: ToolingJSONValue?
    }
    private let binding: RemoteWorkspaceBinding
    private let host: any RemoteRuntimeProbing
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var configured: [String] = []
    private var generation: UInt64 = 0

    init(binding: RemoteWorkspaceBinding, host: any RemoteRuntimeProbing) {
        self.binding = binding
        self.host = host
    }

    var discoveryFailure: String? { lock.withLock { snapshot.failure } }
    func environment() -> [String: String] { lock.withLock { snapshot.environment } }
    func configureProbePaths(_ paths: [String]) {
        lock.withLock {
            guard configured != paths else { return }
            configured = paths
            generation &+= 1
            snapshot = Snapshot()
        }
    }
    func invalidateProbeCache() { lock.withLock { generation &+= 1; snapshot = Snapshot() } }

    func selectJavaRuntime(candidates: [AutomaticJavaCandidate], fallbackID: String?) -> Result<AutomaticJavaSelection, RustCoreBridge.CoreCallError>? {
        let current = lock.withLock { snapshot }
        guard let requirements = current.requirements else {
            return .failure(.init(code: "runtime_discovery_failed",
                message: current.failure ?? L10n.string("Could not discover runtimes on the remote host. Check the connection and refresh."), details: nil))
        }
        return RustCoreBridge().selectJavaRuntime(requirements: requirements, candidates: candidates, fallbackID: fallbackID)
    }

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

    func discover() -> RuntimeDiscoveryResult { discover(isCancelled: { false }) }
    func discover(isCancelled: @Sendable () -> Bool) -> RuntimeDiscoveryResult {
        let (ticket, paths) = lock.withLock { () -> (UInt64, [String]) in
            generation &+= 1
            return (generation, configured)
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
            catch let error as RustCoreBridge.CoreCallError
                where error.code == "workspace_not_found" || error.details?.contains("NOT_A_DIRECTORY") == true { return nil }
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
        func canonical(_ path: String) throws -> String {
            try check()
            return try host.runtimeRealPath(path, session: binding.sessionID)
        }
        do {
            try check()
            next.environment = try host.runtimeEnvironment(session: binding.sessionID)
            try check()
            next.requirements = try host.runtimeRequirements(binding.remoteRoot, session: binding.sessionID)
            guard case .object = next.requirements else { throw ProbeError.invalidRequirements }
            if let requirements = next.requirements {
                _ = try RustCoreBridge().selectJavaRuntime(requirements: requirements, candidates: [], fallbackID: nil).get()
            }
            var homes = Set<String>()
            if let home = next.environment["JAVA_HOME"], home.hasPrefix("/") { homes.insert(home) }
            for path in paths where !path.isEmpty {
                // Use the just-read remote HOME, not the previous snapshot.
                let expanded = path == "~" || path.hasPrefix("~/") ? (next.environment["HOME"] ?? "~") + path.dropFirst() : path
                let resolved = expanded.hasPrefix("/") ? expanded : binding.remoteRoot + "/" + expanded
                homes.insert(resolved)
                if !(try executable(resolved)) {
                    for tool in ["mvn", "mvnd"] {
                        _ = try executable(resolved + "/bin/" + tool)
                        _ = try executable(resolved + "/" + tool)
                    }
                }
            }
            let home = next.environment["HOME"] ?? ""
            var roots = ["/usr/lib/jvm", "/Library/Java/JavaVirtualMachines"]
            if home.hasPrefix("/") {
                roots += [home + "/Library/Java/JavaVirtualMachines",
                          (next.environment["SDKMAN_DIR"] ?? home + "/.sdkman") + "/candidates/java"]
            }
            for root in roots {
                for entry in try entries(root) where entry.isDirectory {
                    let path = root + "/" + entry.name
                    homes.insert(root.contains("JavaVirtualMachines") ? path + "/Contents/Home" : path)
                }
            }
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
                    if entry.name == "java", next.pathJava == nil {
                        let resolved = try canonical(path)
                        if resolved != "/usr/bin/java" {
                            let home = URL(fileURLWithPath: resolved).deletingLastPathComponent().deletingLastPathComponent().path
                            next.pathJava = home
                            homes.insert(home)
                        }
                    }
                }
            }
            for relative in ["mvnw", "gradlew"] { _ = try executable(binding.remoteRoot + "/" + relative) }
            guard homes.count <= 32 else { throw ProbeError.limit }
            var seen = Set<String>()
            for home in homes.sorted() where try executable(home + "/bin/java") {
                let resolved = try canonical(home)
                guard seen.insert(resolved).inserted else { continue }
                next.executables.insert(resolved + "/bin/java")
                try check()
                if let java = MacRuntimeDiscovery.javaRuntime(home: URL(fileURLWithPath: resolved),
                    output: try host.runtimeVersion(home + "/bin/java", session: binding.sessionID)) {
                    next.java.append(java)
                }
            }
            var mavenPaths = next.executables.filter { ["mvn", "mvnd"].contains(URL(fileURLWithPath: $0).lastPathComponent) }.sorted()
            for key in ["MAVEN_HOME", "M2_HOME", "MVND_HOME"] {
                if let home = next.environment[key], home.hasPrefix("/") {
                    let path = home + "/bin/" + (key == "MVND_HOME" ? "mvnd" : "mvn")
                    if try executable(path) { mavenPaths.insert(path, at: 0) }
                }
            }
            guard mavenPaths.count <= 16 else { throw ProbeError.limit }
            for path in mavenPaths {
                try check()
                let output = try host.runtimeVersion(path, session: binding.sessionID)
                if let version = MacRuntimeDiscovery.mavenVersion(in: output) {
                    let resolved = try canonical(path)
                    next.maven.append(MavenRuntimeCandidate(homePath: URL(fileURLWithPath: resolved).deletingLastPathComponent().deletingLastPathComponent().path,
                        executablePath: path, version: version))
                }
            }
            next.java.sort { $0.version.localizedStandardCompare($1.version) == .orderedDescending }
            next.maven.sort { ($0.executablePath.hasSuffix("/mvnd") ? 1 : 0) < ($1.executablePath.hasSuffix("/mvnd") ? 1 : 0) }
        } catch is CancellationError { return RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) }
        catch {
            // A failed/incomplete host snapshot must never authorize a launch.
            next = Snapshot()
            next.failure = L10n.string("Could not discover runtimes on the remote host. Check the connection and refresh.")
        }
        guard !isCancelled() else { return RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) }
        let published = lock.withLock { () -> Bool in
            guard generation == ticket else { return false }
            snapshot = next
            return true
        }
        guard published else { return RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) }
        return RuntimeDiscoveryResult(javaRuntimes: next.java, mavenRuntimes: next.maven)
    }

    private enum ProbeError: Error { case deadline, limit, invalidRequirements }
    func discoverJavaRuntimes() -> [JavaRuntimeCandidate] { lock.withLock { snapshot.java } }
    func discoverJavaRuntimes(isCancelled: @Sendable () -> Bool) -> [JavaRuntimeCandidate] { isCancelled() ? [] : discoverJavaRuntimes() }
    func validJavaHome(path: String) -> URL? {
        let path = normalizedPath(path, relativeTo: binding.root)
        return isExecutable(at: URL(fileURLWithPath: path + "/bin/java")) ? URL(fileURLWithPath: path) : nil
    }
    func javaHomeOnPath(in candidates: [JavaRuntimeCandidate]) -> URL? {
        lock.withLock { snapshot.pathJava.map { URL(fileURLWithPath: $0) } }
    }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { lock.withLock { snapshot.java.first { $0.homePath == homeURL.path } } }
    func isExecutable(at url: URL) -> Bool { lock.withLock { snapshot.executables.contains(normalizedPathWithoutLock(url.path)) } }
    private func normalizedPathWithoutLock(_ path: String) -> String {
        let root = binding.root.path
        return path == root ? binding.remoteRoot : path.hasPrefix(root + "/") ? binding.remoteRoot + path.dropFirst(root.count) : path
    }
    func systemMavenExecutable() -> URL? { lock.withLock { snapshot.maven.first.map { URL(fileURLWithPath: $0.executablePath) } } }
    func mavenExecutable(forHomePath path: String) -> URL? {
        let path = normalizedPath(path, relativeTo: binding.root)
        return [path, path + "/bin/mvnd", path + "/bin/mvn"].first { isExecutable(at: URL(fileURLWithPath: $0)) }.map { URL(fileURLWithPath: $0) }
    }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { lock.withLock { snapshot.maven.first { $0.executablePath == executableURL.path } } }
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
