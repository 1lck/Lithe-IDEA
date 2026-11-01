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

    /// What a provider says one source asks for. `request` stays the manager's own syntax.
    struct Requirement: Equatable, Sendable {
        let request: String
        /// The absolute file that states it.
        let source: String
        let providerID: String
        /// The installation it resolves to; `nil` means the manager has none installed.
        var home: String? = nil
        var version: String? = nil
    }

    /// A machine-local saved choice, validated by Core but never probed.
    struct Pin: Equatable, Sendable {
        let version: String
        let home: String
        /// The directory that saved it: this row's or the nearest ancestor's.
        var directory: String = "."
    }

    /// The first `PATH` match for a declared command, as a child process would find it now.
    /// It is an existing executable, not a verified version or a selection.
    struct Candidate: Equatable, Sendable {
        let executable: String
    }

    /// What the global and automatic layers find for one tool, checked by Core against
    /// native facts and the definition's own version probe. Nothing here grants launch authority.
    struct Detection: Equatable, Sendable {
        /// A declared login-shell home variable and Core's check of the layout it names.
        struct Shell: Equatable, Sendable {
            let variable: String
            let home: String
            var executable: String? = nil
            var version: String? = nil
            /// Core's skip code when no version was established.
            var reason: String? = nil
        }

        /// A discovered home that passed every check, with its probed version.
        struct Installation: Equatable, Sendable {
            let home: String
            let executable: String
            let version: String
            /// `host:system` for a definition scan, otherwise the qualified provider.
            let provider: String
            /// The scanned entry the home was found under, when the definition's home layout
            /// adds a suffix (`jdk-21.jdk` for `jdk-21.jdk/Contents/Home`); it names the installation.
            var location: String? = nil
        }

        /// A discovered home that failed a check, with Core's skip code.
        struct Skipped: Equatable, Sendable {
            let home: String
            let reason: String
        }

        var shell: [Shell] = []
        /// Highest version first.
        var installations: [Installation] = []
        var skipped: [Skipped] = []
        /// The home the automatic layer picks; `nil` with `conflict` means equal highest versions.
        var selected: String? = nil
        var conflict = false
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
        /// Provider answers for this directory, from the nearest queried one.
        var requirements: [Requirement] = []
        var globalRequirements: [Requirement] = []
        var candidate: Candidate? = nil
        /// `nil` when discovery did not run or could not check this tool.
        var detection: Detection? = nil

        var identity: String { "\(directoryID):\(id)" }
    }

    struct Provider: Identifiable, Equatable, Sendable {
        enum QueryState: Equatable, Sendable {
            case notQueried
            case answered(milliseconds: Int)
            /// The provider's own message, shown unmodified.
            case failed(String)
        }

        let id: String
        let title: String
        let pluginID: String
        let pluginName: String
        var tools: [String] = []
        var watchFiles: [String] = []
        var queryState: QueryState = .notQueried
    }

    var workspaceURL: URL? = nil
    var directories: [Directory] = []
    var tools: [Tool] = []
    var providers: [Provider] = []
    var diagnostics: [String] = []
    /// Native inputs providers named; any change revokes this snapshot.
    var watch: [String] = []
}

/// A platform-owned, cancellable read operation; the application model owns stale-result rejection.
protocol ToolchainSettingsLoading: Sendable {
    func load(workspace: URL?) async throws -> ToolchainSettingsSnapshot
}

/// Reports changes to provider inputs outside the workspace, such as global configuration
/// and installation roots. Dropping the returned object ends the observation.
protocol ToolchainInputWatching: Sendable {
    func watch(paths: [String], onChange: @escaping @Sendable () -> Void) -> AnyObject?
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
