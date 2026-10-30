import CryptoKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件后端的工作区上下文、身份与存储范围的决策见 .agents/notes/implemented/architecture/2026-10-30-plugin-backend-workspace-context.md

/// One open workspace in one window, as plugin backends see it (function
/// protocol 3). `generation` grows whenever the window's folders or
/// authority change, so a backend holding an older one learns that its
/// view is stale (`plugin.host.contextExpired`) instead of acting on it.
struct PluginWorkspaceContext: Equatable, Sendable {
    /// Where the workspace's files and processes are. Only `local` is
    /// served by file and process services today; they refuse `remote`
    /// with `plugin.host.authorityUnsupported`.
    enum Authority: Equatable, Sendable {
        case local
        /// A workspace on an SSH host; `id` is the opaque connection ID.
        case remote(id: String)
    }

    struct Folder: Equatable, Sendable {
        /// Stable for the same location across restarts, without the path.
        let rootID: String
        let name: String
        /// The folder on this Mac. For a remote workspace it is the empty
        /// placeholder, never the workspace: services must not read it.
        let localURL: URL
        /// The folder on the remote host, for a remote workspace.
        let remotePath: String?
    }

    let contextID: String
    let generation: Int
    let name: String
    let authority: Authority
    let folders: [Folder]
    /// Keys the per-plugin state directory of this workspace; it names the
    /// location, so reopening the same workspace finds the same state.
    let stateKey: String

    var reference: PluginWorkspaceContextReference {
        PluginWorkspaceContextReference(contextID: contextID, generation: generation)
    }
}

/// The workspace contexts of every window, shared by all windows because
/// plugin backends are. A window owns at most one context; it opens it when
/// it opens a workspace and closes it when the workspace closes.
@MainActor
final class PluginWorkspaceContexts {
    static let shared = PluginWorkspaceContexts()

    /// Grows whenever a context opens, closes, or changes.
    private(set) var revision = 1
    private var contextsByOwner: [ObjectIdentifier: PluginWorkspaceContext] = [:]
    private var closeObservers: [UUID: @MainActor (String) -> Void] = [:]
    private var openObservers: [UUID: @MainActor (PluginWorkspaceContext) -> Void] = [:]
    private var nextContextNumber = 1

    init() {}

    /// Every open context, ordered by context ID.
    var contexts: [PluginWorkspaceContext] {
        contextsByOwner.values.sorted { $0.contextID < $1.contextID }
    }

    func context(ownedBy owner: AnyObject) -> PluginWorkspaceContext? {
        contextsByOwner[ObjectIdentifier(owner)]
    }

    /// The context a reference names, when it is open and of that
    /// generation. Anything else is `plugin.host.contextExpired`.
    func resolve(_ reference: PluginWorkspaceContextReference) -> Result<PluginWorkspaceContext, PluginHostServiceError> {
        guard let context = contextsByOwner.values.first(where: { $0.contextID == reference.contextID }),
              context.generation == reference.generation else {
            return .failure(PluginHostServiceError(
                .contextExpired,
                L10n.string("The workspace context is no longer current. Ask the host for it again.")
            ))
        }
        return .success(context)
    }

    /// Opens or replaces the window's context. The same workspace again
    /// keeps the context unchanged; another one keeps the context ID with
    /// the next generation, and closes what the old one owned.
    @discardableResult
    func open(owner: AnyObject, rootURL: URL, remote: (connectionID: String, remoteRoot: String)?) -> PluginWorkspaceContext {
        let root = rootURL.standardizedFileURL
        let authority: PluginWorkspaceContext.Authority = remote.map { .remote(id: $0.connectionID) } ?? .local
        let stateKey: String
        let name: String
        if let remote {
            stateKey = "remote:\(remote.connectionID):\(remote.remoteRoot)"
            name = (remote.remoteRoot as NSString).lastPathComponent.isEmpty
                ? remote.remoteRoot
                : (remote.remoteRoot as NSString).lastPathComponent
        } else {
            stateKey = root.path
            name = root.lastPathComponent
        }
        let folder = PluginWorkspaceContext.Folder(
            rootID: Self.rootID(stateKey), name: name, localURL: root, remotePath: remote?.remoteRoot
        )
        let key = ObjectIdentifier(owner)
        let previous = contextsByOwner[key]
        if let previous, previous.authority == authority, previous.folders == [folder] {
            return previous
        }
        let contextID: String
        if let previous {
            contextID = previous.contextID
        } else {
            contextID = "w-\(nextContextNumber)"
            nextContextNumber += 1
        }
        let context = PluginWorkspaceContext(
            contextID: contextID,
            generation: (previous?.generation ?? 0) + 1,
            name: name,
            authority: authority,
            folders: [folder],
            stateKey: stateKey
        )
        contextsByOwner[key] = context
        revision += 1
        if previous != nil {
            for observer in closeObservers.values { observer(contextID) }
        }
        for observer in openObservers.values { observer(context) }
        return context
    }

    /// Closes the window's context; nothing happens when it has none.
    func close(owner: AnyObject) {
        guard let context = contextsByOwner.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        revision += 1
        for observer in closeObservers.values { observer(context.contextID) }
    }

    /// Called with the context ID whenever a context closes or moves to a
    /// new generation, so what belonged to it is disposed.
    @discardableResult
    func observeClose(_ observer: @escaping @MainActor (String) -> Void) -> UUID {
        let id = UUID()
        closeObservers[id] = observer
        return id
    }

    /// Called whenever a context opens or moves to a new generation.
    @discardableResult
    func observeOpen(_ observer: @escaping @MainActor (PluginWorkspaceContext) -> Void) -> UUID {
        let id = UUID()
        openObservers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        closeObservers[id] = nil
        openObservers[id] = nil
    }

    /// `r` and 16 hex digits of the location's SHA-256.
    static func rootID(_ location: String) -> String {
        "r" + SHA256.hash(data: Data(location.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Names the state directory of a context without the user's path.
    static func stateDigest(_ stateKey: String) -> String {
        SHA256.hash(data: Data(stateKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
