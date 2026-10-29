import Foundation
import LitheCoreContracts

/// Where a tool candidate came from.  The value is intentionally platform
/// neutral so the same run/DAP UI can explain a Windows registry entry or a
/// macOS Homebrew/Xcode candidate without importing platform frameworks.
struct RuntimeToolGuidance: Equatable, Sendable {
    let command: String
    let displayName: String
    let summary: String
    let recovery: String

    init(
        command: String,
        displayName: String? = nil,
        summary: String,
        recovery: String
    ) {
        self.command = command
        self.displayName = displayName ?? command
        self.summary = summary
        self.recovery = recovery
    }

    var message: String { summary + " " + recovery }
}

/// Platform adapters may provide richer candidates than a bare PATH scan.
/// The core service only consumes this value and never touches the file system
/// itself, which keeps the Windows implementation free to use its own rules.
protocol RuntimeToolDiscovery: Sendable {
    func candidates(
        for command: String,
        projectURL: URL?,
        environment: [String: String]
    ) -> [RuntimeToolCandidate]

    func guidance(
        for command: String,
        projectURL: URL?,
        environment: [String: String]
    ) -> RuntimeToolGuidance
}

/// Safe no-op default used by non-platform composition roots.  The core
/// service still performs the protocol-level PATH lookup through
/// `RuntimeLocator`; richer discovery is injected by the platform adapter.
struct DefaultRuntimeToolDiscovery: RuntimeToolDiscovery {
    func candidates(
        for command: String,
        projectURL: URL?,
        environment: [String: String]
    ) -> [RuntimeToolCandidate] { [] }

    func guidance(
        for command: String,
        projectURL: URL?,
        environment: [String: String]
    ) -> RuntimeToolGuidance {
        RuntimeToolGuidance(
            command: command,
            summary: "\(command) is not available in the current toolchain.",
            recovery: "Install it with your platform's package manager or add its executable directory to PATH."
        )
    }
}

protocol RuntimeLocator: Sendable {
    /// A failed host probe must not be presented as an empty local toolchain.
    var discoveryFailure: String? { get }
    func normalizedPath(_ path: String, relativeTo root: URL?) -> String
    func configureProbePaths(_ paths: [String])
    /// Remote adapters select from a host-read snapshot without UI-thread I/O.
    func selectJavaRuntime(candidates: [AutomaticJavaCandidate], fallbackID: String?) -> Result<AutomaticJavaSelection, RustCoreBridge.CoreCallError>?
    func environment() -> [String: String]
    /// Platform search path used only when a launch environment omits PATH.
    func defaultExecutableSearchPath() -> String?
    func discover() -> RuntimeDiscoveryResult
    func discover(isCancelled: @Sendable () -> Bool) -> RuntimeDiscoveryResult
    /// Java-only probing for launch paths; never runs Maven or other tools.
    func discoverJavaRuntimes() -> [JavaRuntimeCandidate]
    func discoverJavaRuntimes(isCancelled: @Sendable () -> Bool) -> [JavaRuntimeCandidate]
    /// Explicit refresh invalidates the platform's in-memory version probes.
    func invalidateProbeCache()
    func validJavaHome(path: String) -> URL?
    /// Returns the candidate reached by PATH, resolving platform symlinks.
    func javaHomeOnPath(in candidates: [JavaRuntimeCandidate]) -> URL?
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate?
    func isExecutable(at url: URL) -> Bool
    func systemMavenExecutable() -> URL?
    func mavenExecutable(forHomePath path: String) -> URL?
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate?
}

extension RuntimeLocator {
    var discoveryFailure: String? { nil }
    func configureProbePaths(_ paths: [String]) {}
    func selectJavaRuntime(candidates: [AutomaticJavaCandidate], fallbackID: String?) -> Result<AutomaticJavaSelection, RustCoreBridge.CoreCallError>? { nil }
    func normalizedPath(_ path: String, relativeTo root: URL?) -> String {
        let normalized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        guard !(normalized as NSString).isAbsolutePath, let root else { return normalized }
        return root.appendingPathComponent(normalized).standardizedFileURL.path
    }
    func discover(isCancelled: @Sendable () -> Bool) -> RuntimeDiscoveryResult {
        isCancelled() ? RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) : discover()
    }
    func defaultExecutableSearchPath() -> String? { nil }
    func invalidateProbeCache() {}
    func discoverJavaRuntimes(isCancelled: @Sendable () -> Bool) -> [JavaRuntimeCandidate] {
        isCancelled() ? [] : discoverJavaRuntimes()
    }
    func discoverJavaRuntimes() -> [JavaRuntimeCandidate] { discover().javaRuntimes }
    func javaHomeOnPath(in candidates: [JavaRuntimeCandidate]) -> URL? { nil }
}

/// Synchronous host I/O used exclusively by runtime discovery's owned worker.
protocol RemoteRuntimeProbing: Sendable {
    func runtimeEnvironment(session: String) throws -> [String: String]
    func runtimeDirectory(_ path: String, session: String) throws -> [RemoteDirectoryEntry]
    func runtimeRealPath(_ path: String, session: String) throws -> String
    func runtimeExecutable(_ path: String, session: String) throws -> Bool
    func runtimeVersion(_ executable: String, session: String) throws -> String
    func runtimeRequirements(_ root: String, session: String) throws -> ToolingJSONValue
}

/// Shared selection policy; platform locators still own executable validation
/// and version probing. Requirements are read through Core's existing document.
protocol JavaRuntimeSelecting: Sendable {
    func selectJavaRuntime(at root: URL?, candidates: [AutomaticJavaCandidate], fallbackID: String?) -> Result<AutomaticJavaSelection, RustCoreBridge.CoreCallError>
}

struct AutomaticJavaCandidate: Codable, Sendable {
    let id: String
    let version: String
    let priority: UInt32
}

struct AutomaticJavaSelection: Decodable, Sendable {
    let id: String?
    let warning: String?
}
