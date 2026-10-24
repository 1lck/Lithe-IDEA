import Foundation

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

    func showRemoteConnections() {
        guard canManageRemoteConnections else { return }
        workbenchFeature.isRemoteConnectionsPresented = true
    }

    /// The state of one Remote Development window; nil when the platform
    /// offers no remote connections.
    func makeRemoteConnectionsFeature() -> RemoteConnectionsFeatureModel? {
        guard let services = services.remoteConnections else { return nil }
        return RemoteConnectionsFeatureModel(
            store: services.store, prober: services.prober, sessions: services.sessions,
            locator: services.locator, servers: services.servers,
            openWorkspace: { [weak self] connection, folder, session in
                try self?.openRemoteWorkspace(connection: connection, folder: folder, session: session, services: services)
            }
        )
    }

    /// Opens `folder` on the connected host as this window's workspace. A
    /// workspace already open for the same folder hands over to the new
    /// connection, whose session the registry keeps until the app quits.
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
        openProject(root)
    }
}
