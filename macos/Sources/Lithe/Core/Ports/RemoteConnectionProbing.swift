import Foundation
import LitheCoreContracts

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// How a saved SSH connection proves the user's identity. Every method still
/// lets OpenSSH ask follow-up questions, such as a one-time code.
enum RemoteSSHAuthentication: String, Codable, CaseIterable, Sendable {
    /// OpenSSH's own order: keys and agent first, then interactive methods.
    case auto
    /// Keys offered by the running SSH agent or the SSH configuration.
    case agent
    /// Only the chosen private key file.
    case privateKey
    /// Password or keyboard-interactive prompts, without trying keys.
    case password
}

/// The facts Core needs to reach a host. Display names and secrets stay in
/// the app; `nil` fields keep the user's SSH configuration.
struct RemoteSSHTarget: Encodable, Equatable, Sendable {
    var host: String
    var port: Int?
    var user: String?
    var authentication: RemoteSSHAuthentication
    var identityFile: String?
    var connectTimeoutSeconds: Int?
    var keepAliveSeconds: Int?
}

/// Outcome of `remote.probe`; see `shared/contracts/rust-core-api.md`.
enum RemoteProbeStatus: String, Decodable, Equatable, Sendable {
    case connected
    case unsupportedPlatform
    case authenticationFailed
    case hostKeyRejected
    case unreachable
    case failed
}

struct RemoteProbedHost: Decodable, Equatable, Sendable {
    let system: String
    let machine: String
    let homeDirectory: String?
    /// Rust target of the server build for this host; `nil` when none ships.
    let serverTarget: String?
    let details: RemoteHostDetails
}

/// Facts about a host for display; each is `nil` when it could not be read.
struct RemoteHostDetails: Codable, Equatable, Sendable {
    var hostName: String?
    /// For example `Ubuntu 22.04.4 LTS`.
    var operatingSystem: String?
    var kernel: String?
    var cpuCount: Int?
    var memoryBytes: Int64?
    /// File system that holds the home directory.
    var diskTotalBytes: Int64?
    var diskAvailableBytes: Int64?
    var uptimeSeconds: Int64?
}

/// Where a public address is registered, from an IP lookup service.
struct RemoteHostLocation: Codable, Equatable, Sendable {
    var city: String?
    var region: String?
    var country: String?
    /// Network operator, for example `AS45090 Tencent`.
    var organization: String?
    /// The address is private or reserved, so it has no public location.
    var isPrivate: Bool
}

protocol RemoteHostLocating: Sendable {
    /// Resolves a host name to its first address on this Mac, without
    /// contacting any service other than the system resolver.
    func resolveAddress(of host: String) async -> String?

    /// Looks up `address` with an external IP information service. Only
    /// called when the user asks, because it sends the address to that
    /// service.
    func locate(_ address: String) async -> Result<RemoteHostLocation, RemoteProbeFailure>
}

struct RemoteProbeResult: Decodable, Equatable, Sendable {
    let status: RemoteProbeStatus
    let host: RemoteProbedHost?
    /// Redacted end of OpenSSH's standard error.
    let diagnostics: String
}

/// A question OpenSSH asked while connecting: a password, a key passphrase,
/// a one-time code, or whether to trust an unknown host key.
struct RemoteAuthenticationPrompt: Decodable, Equatable, Identifiable, Sendable {
    let requestId: String
    let prompt: String
    /// Whether the answer should be typed into a secure field.
    let secret: Bool
    /// Starts at 1; a higher value means the previous answer was rejected.
    let attempt: Int

    var id: String { requestId }
}

/// The probe could not run at all, for example because `ssh` is missing or
/// the connection is malformed. Connection failures are results instead.
struct RemoteProbeFailure: Error, Equatable, Sendable {
    let code: String
    let message: String
}

protocol RemoteConnectionProbing: Sendable {
    /// Connects to `target` and reports its platform. `onPrompt` is called
    /// from a background thread for each question; answer it with
    /// `answer(_:with:)`. Cancelling the calling task stops the probe.
    func probe(
        _ target: RemoteSSHTarget,
        onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void
    ) async -> Result<RemoteProbeResult, RemoteProbeFailure>

    /// Answers a prompt once; `nil` declines it. Returns `false` for a prompt
    /// that is no longer waiting.
    func answer(_ requestID: String, with answer: String?) -> Bool
}

/// One read-only server build shipped with the app, uploaded to hosts of
/// its platform on first connect.
struct RemoteServerBuild: Encodable, Equatable, Sendable {
    /// Rust target triple, for example `x86_64-unknown-linux-musl`.
    let target: String
    let path: String
}

/// The server builds shipped with this app.
struct RemoteServerBundle: Equatable, Sendable {
    let version: String
    let builds: [RemoteServerBuild]

    func supports(_ target: String?) -> Bool {
        guard let target else { return false }
        return builds.contains { $0.target == target }
    }
}

/// An open connection to a host's server; Core keeps it until disconnected.
struct RemoteOpenedSession: Decodable, Equatable, Sendable {
    let id: String
    /// Whether this connection uploaded the server.
    let uploaded: Bool
    let hostName: String
    let userName: String?
    let homeDirectory: String?
}

/// Outcome of `remote.connect`: `session` is set only when connected.
struct RemoteConnectResult: Decodable, Equatable, Sendable {
    let status: RemoteProbeStatus
    let session: RemoteOpenedSession?
    let host: RemoteProbedHost?
    let diagnostics: String
}

/// One entry of a remote directory listing.
struct RemoteDirectoryEntry: Decodable, Equatable, Identifiable, Sendable {
    struct Metadata: Decodable, Equatable, Sendable {
        let kind: String
        /// Kind of a symbolic link's target; `nil` for other entries and
        /// for dangling links.
        let symlinkTargetKind: String?
        let size: Int64?
        /// Modification time in milliseconds since the Unix epoch.
        let modifiedMs: Int64?
        let mode: UInt32?
        let symlinkTargetMode: UInt32?

        init(kind: String, symlinkTargetKind: String? = nil, size: Int64? = nil, modifiedMs: Int64? = nil, mode: UInt32? = nil, symlinkTargetMode: UInt32? = nil) {
            self.kind = kind
            self.symlinkTargetKind = symlinkTargetKind
            self.size = size
            self.modifiedMs = modifiedMs
            self.mode = mode
            self.symlinkTargetMode = symlinkTargetMode
        }
    }

    let name: String
    let metadata: Metadata

    var id: String { name }

    /// Directories, and links that resolve to one, can be opened.
    var isDirectory: Bool {
        metadata.kind == "directory" || (metadata.kind == "symlink" && metadata.symlinkTargetKind == "directory")
    }
}

protocol RemoteSessionConnecting: Sendable {
    /// Connects, uploading the matching server from `servers` when the host
    /// has no identical one, and keeps the connection open in Core.
    /// Prompts and cancellation behave as for `probe`.
    func connect(
        _ target: RemoteSSHTarget,
        servers: RemoteServerBundle,
        onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void
    ) async -> Result<RemoteConnectResult, RemoteProbeFailure>

    /// Lists `path` on the host of an open connection.
    func readDirectory(_ path: String, session id: String) async -> Result<[RemoteDirectoryEntry], RemoteProbeFailure>

    /// Closes a connection; closing a closed one does nothing.
    func disconnect(session id: String) async
}

/// Version of a remote file as the host reports it; a write that names it
/// fails instead of replacing a file that changed since it was read.
struct RemoteFileVersion: Codable, Equatable, Sendable {
    let size: Int64
    let modifiedMs: Int64?
}

enum RemoteWriteOutcome: Equatable, Sendable {
    case saved(RemoteFileVersion)
    /// The file changed since it was read, or a new file already exists.
    case conflict
}

/// File access over an open connection, for workspace adapters. Calls block
/// on the network, so they run on background threads only.
protocol RemoteWorkspaceTransport: Sendable {
    func listDirectory(_ path: String, session id: String) throws -> [RemoteDirectoryEntry]
    func readFile(_ path: String, session id: String) throws -> (data: Data, version: RemoteFileVersion)
    func writeFile(
        _ data: Data, to path: String, expected: RemoteFileVersion?, session id: String
    ) throws -> RemoteWriteOutcome
    func mutate(_ mutation: RemoteFileMutation, session: String) throws
    func watch(
        root: String, session: String,
        onEvent: @escaping @Sendable (RemoteWatchEvent) -> Void
    ) async throws
}

enum RemoteFileMutation: Sendable, Equatable {
    case createDirectory(path: String, recursive: Bool)
    case copy(from: String, to: String)
    case move(from: String, to: String)
    case remove(path: String)
    case trash(path: String)
}

enum RemoteWatchEvent: Sendable, Equatable {
    /// A new subscription needs a rescan to cover the startup window.
    case started
    case changed(paths: [String], overflow: Bool)
    case invalidated(rootRemoved: Bool)
}

extension RemoteWorkspaceTransport {
    func mutate(_ mutation: RemoteFileMutation, session: String) throws {
        throw CocoaError(.featureUnsupported)
    }

    func watch(root: String, session: String, onEvent: @escaping @Sendable (RemoteWatchEvent) -> Void) async throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// A PTY on the workspace host. Environment contains explicit overrides only;
/// the remote account owns HOME, PATH, shell selection and login profiles.
struct RemoteTerminalRequest: Encodable, Equatable, Sendable {
    let argv: [String]?
    let cwd: String
    let env: [String: String]
    let columns: UInt16
    let rows: UInt16
}

enum RemoteTerminalEvent: Equatable, Sendable {
    case started(id: UInt64, pid: Int32)
    case output(Data)
    case exited(Int32?)
}

protocol RemoteTerminalConnecting: Sendable {
    /// Owns the PTY until exit. Cancelling this task closes its entire process tree.
    func runTerminal(
        _ request: RemoteTerminalRequest, session: String,
        onEvent: @escaping @Sendable (RemoteTerminalEvent) -> Void
    ) async -> Result<Void, RemoteProbeFailure>
    func writeTerminal(_ data: Data, id: UInt64, session: String) async throws
    func resizeTerminal(id: UInt64, columns: UInt16, rows: UInt16, session: String) async throws
}

/// A non-interactive process with an explicit host working directory.
struct RemoteProcessRequest: Encodable, Equatable, Sendable {
    let argv: [String]
    let cwd: String
    let env: [String: String]
    let environment = "login"
    let processId = 0
}

enum RemoteProcessEvent: Equatable, Sendable {
    case output(Data, standardError: Bool)
}

struct RemoteProcessResult: Decodable, Equatable, Sendable {
    let exitCode: Int32?
    let signal: Int32?
}

protocol RemoteProcessRunning: Sendable {
    /// Owns the process tree through exit, timeout, or cancellation. Output is
    /// delivered in host order and stderr remains distinct from stdout.
    func runProcess(
        _ request: RemoteProcessRequest, session: String, timeout: Duration?,
        onEvent: @escaping @Sendable (RemoteProcessEvent) -> Void
    ) async throws -> RemoteProcessResult
}

struct RemoteBuildFileMetadata: Equatable, Sendable {
    let isExecutable: Bool
}

protocol RemoteBuildFileProbing: Sendable {
    /// Resolves links on the host. Only a missing file returns nil; transport
    /// and permission failures remain failures. Calls belong on a worker.
    func buildFileMetadata(_ path: String, session: String) throws -> RemoteBuildFileMetadata?
}

/// Host-owned mutable build state. Blocking operations run on a platform worker.
protocol RemoteBuildStateAccess: Sendable {
    func prepareBuildState(pluginID: String, buildSystemID: String, workspacePath: String, session: String) throws -> String
    func removeBuildOutputFile(_ path: String, session: String) throws
}

/// Immutable plugin snapshots use the same generic host filesystem as builds.
/// Trust and target-platform selection remain in the package adapter.
struct RemotePluginHost: Decodable, Equatable, Sendable {
    let os: String
    let arch: String
    let homeDirectory: String?
    let features: [String]

    var platform: String? {
        let system: String
        switch os { case "linux": system = "linux"; case "macos": system = "darwin"; default: return nil }
        switch arch { case "x86_64": return system + "-x64"; case "aarch64": return system + "-arm64"; default: return nil }
    }

    var templateArchitecture: String { arch == "aarch64" ? "arm64" : arch }
}

protocol RemotePluginFileAccess: Sendable {
    func pluginHost(session: String) async throws -> RemotePluginHost
    func pluginRequest(_ method: String, params: ToolingJSONValue, session: String) async throws -> ToolingJSONValue
    func uploadPluginFile(_ source: URL, to path: String, sha256: String, mode: UInt32, session: String) async throws
}

protocol RemotePluginPackageDeploying: Sendable {
    func buildRequiresPackage(pluginID: String, buildSystemID: String, packageURL: URL) throws -> Bool
    func deploy(pluginID: String, packageURL: URL, session: String) async throws -> RemoteDeployedPluginPackage
}

struct RemoteDeployedPluginPackage: Sendable {
    let packageURL: URL
    let manifest: Data
    let architecture: String
    let release: @Sendable () async -> Void
}

/// Read-only shell discovery on one host. Calls block and belong on a worker.
protocol RemoteShellProbing: Sendable {
    func shellEnvironment(session: String) throws -> [String: String]
    func registeredShells(session: String) throws -> String
    func runtimeDirectory(_ path: String, session: String) throws -> [RemoteDirectoryEntry]
    func runtimeExecutable(_ path: String, session: String) throws -> Bool
}
