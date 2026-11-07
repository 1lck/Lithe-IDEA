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
    func environment() -> [String: String]
    /// Platform search path used only when a launch environment omits PATH.
    func defaultExecutableSearchPath() -> String?
    /// Reads the host's login environment and the executables on its PATH.
    /// Only adapters that cannot answer synchronously (a remote host) do work
    /// here; the call runs on a worker queue, never on the UI executor.
    func probeHost(isCancelled: @Sendable () -> Bool)
    /// Explicit refresh invalidates the platform's in-memory probes.
    func invalidateProbeCache()
    func isExecutable(at url: URL) -> Bool
}

extension RuntimeLocator {
    var discoveryFailure: String? { nil }
    func normalizedPath(_ path: String, relativeTo root: URL?) -> String {
        let normalized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        guard !(normalized as NSString).isAbsolutePath, let root else { return normalized }
        return root.appendingPathComponent(normalized).standardizedFileURL.path
    }
    func defaultExecutableSearchPath() -> String? { nil }
    func probeHost(isCancelled: @Sendable () -> Bool) {}
    func invalidateProbeCache() {}
}

/// Synchronous host I/O used exclusively by runtime discovery's owned worker.
protocol RemoteRuntimeProbing: Sendable {
    func runtimeEnvironment(session: String) throws -> [String: String]
    func runtimeDirectory(_ path: String, session: String) throws -> [RemoteDirectoryEntry]
    func runtimeExecutable(_ path: String, session: String) throws -> Bool
}
