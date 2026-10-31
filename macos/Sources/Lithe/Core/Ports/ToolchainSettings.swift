import Foundation

/// Read-only presentation facts; loading a snapshot does not grant launch authority.
/// Every value is observed or saved; nothing stands in for a provider query that has not run.
struct ToolchainSettingsSnapshot: Equatable, Sendable {
    /// A provider-declared version file that exists, relative to the workspace root.
    struct VersionFile: Equatable, Sendable {
        let path: String
        /// Snapshot provider identities that watch this file.
        let providerIDs: [String]
    }

    struct Directory: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        var depth: Int = 0
        /// Version files in this directory itself; ancestors' files are not repeated.
        var versionFiles: [VersionFile] = []
    }

    /// A machine-local saved choice, validated by Core but never probed.
    struct Pin: Equatable, Sendable {
        let version: String
        let home: String
        /// The directory that saved it: this row's or the nearest ancestor's.
        var directory: String = "."
    }

    /// The first declared automatic candidate a child process would find now.
    /// It is an existing executable, not a verified version or a selection.
    struct Candidate: Equatable, Sendable {
        enum Origin: Equatable, Sendable {
            case variable(String)
            case path
        }

        let executable: String
        let origin: Origin
    }

    struct Tool: Identifiable, Equatable, Sendable {
        let id: String
        var directoryID: String = "."
        let displayName: String
        let pluginID: String
        let pluginName: String
        var iconName: String? = nil
        var pin: Pin? = nil
        /// Version files watched by providers of this tool, nearest directory first.
        var versionFiles: [VersionFile] = []
        var candidate: Candidate? = nil

        var identity: String { "\(directoryID):\(id)" }
    }

    struct Provider: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let pluginID: String
        let pluginName: String
        var tools: [String] = []
        var watchFiles: [String] = []
    }

    var workspaceURL: URL? = nil
    var directories: [Directory] = []
    var tools: [Tool] = []
    var providers: [Provider] = []
    var diagnostics: [String] = []
}

/// A platform-owned, cancellable read operation; the application model owns stale-result rejection.
protocol ToolchainSettingsLoading: Sendable {
    func load(workspace: URL?) async throws -> ToolchainSettingsSnapshot
}

/// What the settings pages may show about the login-shell read. Only `PATH`'s
/// directories are exposed; other variables may hold secrets and appear as a count.
struct LoginShellEnvironmentSnapshot: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case notRead, reading, read, failed, disabled
    }

    enum PathOrigin: String, Equatable, Sendable {
        case loginShell, inherited
    }

    struct PathEntry: Equatable, Sendable {
        let path: String
        let origin: PathOrigin
    }

    var shell: String = ""
    var state: State = .notRead
    var variableCount: Int? = nil
    var durationMilliseconds: Int? = nil
    var readAt: Date? = nil
    /// Startup applied the cached login `PATH` before this launch's read finished.
    var startedFromCache = false
    /// The `PATH` this process and its children use, in lookup order.
    var processPath: [PathEntry] = []
    /// A later read changed `PATH`; running and new children keep the startup value until restart.
    var pathChangedSinceLaunch = false
}

/// Reading never changes this process's `PATH`; only variables children lack are refreshed.
protocol LoginShellEnvironmentInspecting: Sendable {
    func inspect() -> LoginShellEnvironmentSnapshot
    /// Joins a read already in progress instead of starting a second shell.
    func reread() async -> LoginShellEnvironmentSnapshot
}
