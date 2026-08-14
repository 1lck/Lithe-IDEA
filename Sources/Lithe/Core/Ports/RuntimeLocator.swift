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
    func environment() -> [String: String]
    func discover() -> RuntimeDiscoveryResult
    func validJavaHome(path: String) -> URL?
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate?
    func isExecutable(at url: URL) -> Bool
    func systemMavenExecutable() -> URL?
    func mavenExecutable(forHomePath path: String) -> URL?
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate?
    func systemJDBExecutable() -> URL?
}
