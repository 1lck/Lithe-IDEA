import Foundation
import LitheModuleAPI

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// Dependencies of the Remote Development window.
struct RemoteConnectionServices {
    let store: RemoteConnectionStore
    let prober: any RemoteConnectionProbing
    let sessions: any RemoteSessionConnecting
    let locator: any RemoteHostLocating
    let workspaces: RemoteWorkspaceRegistry
    /// Creates the empty local placeholder root for a remote folder.
    let prepareWorkspaceRoot: (UUID, String) throws -> URL
    /// Servers shipped with the app; `nil` disables connecting and browsing.
    let servers: RemoteServerBundle?
}

@MainActor
extension AppModel {
    var canManageRemoteConnections: Bool { services.remoteConnections != nil }

    var hasSavedRemoteConnections: Bool {
        guard let services = services.remoteConnections else { return false }
        return !services.store.load().isEmpty
    }

    func showRemoteConnections() {
        guard canManageRemoteConnections else { return }
        workbenchFeature.remoteReconnect = nil
        workbenchFeature.isRemoteConnectionsPresented = true
    }

    /// Starts listening for lost connections; the window showing the lost
    /// workspace offers to reconnect it.
    func observeRemoteConnectionLoss() {
        remoteLossObserver = NotificationCenter.default.addObserver(
            forName: .remoteWorkspaceConnectionLost, object: nil, queue: .main
        ) { [weak self] notification in
            guard let loss = notification.userInfo?[RemoteConnectionLoss.userInfoKey] as? RemoteConnectionLoss else { return }
            MainActor.assumeIsolated { self?.offerReconnect(loss) }
        }
    }

    private func offerReconnect(_ loss: RemoteConnectionLoss) {
        guard workspaceURL?.standardizedFileURL == loss.root.standardizedFileURL else { return }
        showNotification(L10n.string("The connection to the remote host was lost. Reconnect to continue."))
        workbenchFeature.remoteReconnect = loss
        workbenchFeature.isRemoteConnectionsPresented = true
    }

    /// The state of one Remote Development window; nil when the platform
    /// offers no remote connections.
    func makeRemoteConnectionsFeature() -> RemoteConnectionsFeatureModel? {
        guard let services = services.remoteConnections else { return nil }
        return RemoteConnectionsFeatureModel(
            store: services.store, prober: services.prober, sessions: services.sessions,
            locator: services.locator, servers: services.servers,
            reconnect: workbenchFeature.remoteReconnect,
            openWorkspace: { [weak self] connection, folder, session in
                try self?.openRemoteWorkspace(connection: connection, folder: folder, session: session, services: services)
            }
        )
    }

    /// Ends the connection of a closed remote workspace, so its OpenSSH
    /// process and remote server do not outlive the project.
    func releaseRemoteWorkspace(at root: URL) {
        guard let services = services.remoteConnections,
              let binding = services.workspaces.unregister(root: root) else { return }
        let sessions = services.sessions
        Task { await sessions.disconnect(session: binding.sessionID) }
    }

    /// Opens `folder` on the connected host as this window's workspace. A
    /// workspace already open for the same folder hands over to the new
    /// connection, whose session the registry keeps until the project closes or the app quits.
    private func openRemoteWorkspace(
        connection: RemoteSSHConnection, folder: String, session: RemoteOpenedSession,
        services: RemoteConnectionServices
    ) throws {
        let root = try services.prepareWorkspaceRoot(connection.id, folder)
        if let previous = services.workspaces.unregister(root: root) {
            let sessions = services.sessions
            Task { await sessions.disconnect(session: previous.sessionID) }
        }
        services.workspaces.register(RemoteWorkspaceBinding(
            root: root, remoteRoot: folder, sessionID: session.id, connectionID: connection.id
        ))
        workbenchFeature.isRemoteConnectionsPresented = false
        workbenchFeature.remoteReconnect = nil
        openProject(root)
    }
}
