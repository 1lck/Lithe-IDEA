import Foundation

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

        init(kind: String, symlinkTargetKind: String? = nil, size: Int64? = nil, modifiedMs: Int64? = nil) {
            self.kind = kind
            self.symlinkTargetKind = symlinkTargetKind
            self.size = size
            self.modifiedMs = modifiedMs
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
}
