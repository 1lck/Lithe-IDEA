import Foundation
import LitheCoreContracts
import LitheExecutionModule

// Note: 插件网页内容与宿主窗口的分工见 .agents/notes/implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md

/// What a plugin page may reach in this project window: the build feature
/// the host's own Build window uses, the editor, and the Build output.
@MainActor
extension AppModel: PluginWebBridgeHost {
    var pluginWebWorkspaceURL: URL? { workspaceURL }

    func pluginWebBuildSystems(activate: Bool) async -> (any PluginWebBuildAccess)? {
        if !activate { return buildSystemsFeatureIfActive }
        guard workspaceURL != nil, let access = await activateExecutionModule() else { return nil }
        loadBuildSystems(access)
        return access.buildSystems
    }

    func pluginWebShowBuildOutput() {
        showToolWindow(.buildOutput)
    }

    func pluginWebOpenFile(_ url: URL, line: Int?, column: Int?) -> Bool {
        guard services.fileStorage.metadata(for: url)?.isRegularFile == true else { return false }
        openSourceLocation(url: url, line: line ?? 1, column: column)
        return true
    }

    func pluginWebConfirmProcessStart(_ consent: PluginWebProcessConsent) async -> Bool {
        await services.pluginWebPages.confirmProcessStart(consent)
    }

    func pluginWebChooseFile(_ request: PluginWebFileRequest) async -> URL? {
        await services.pluginWebPages.chooseFile(request)
    }

    var pluginWebBackends: (any PluginBackendRequesting)? { services.pluginWebPages.backends }

    var pluginWebWorkspaceContext: PluginWorkspaceContextReference? {
        services.pluginWorkspaceContexts?.context(ownedBy: self)?.reference
    }

    // Note: 工作区上下文与 onWorkspaceOpen 激活见 .agents/notes/implemented/architecture/2026-10-30-plugin-backend-workspace-context.md

    /// Gives the workspace this window opens a context for plugin backends,
    /// with the SSH host as its authority when it is remote, then starts
    /// the `onWorkspaceOpen` backends once the window shows it. Their start
    /// never delays the workspace.
    func openPluginWorkspaceContext(at rootURL: URL) {
        guard let contexts = services.pluginWorkspaceContexts else { return }
        let root = rootURL.standardizedFileURL
        let binding = services.remoteConnections?.workspaces.binding(forRoot: root)
        contexts.open(
            owner: self,
            rootURL: root,
            remote: binding.map { (connectionID: $0.connectionID.uuidString, remoteRoot: $0.remoteRoot) }
        )
        Task { @MainActor [weak self] in
            guard let self, !self.isProjectSessionClosed, self.workspaceURL == root else { return }
            self.services.pluginBackendActivation?.activate(event: "onWorkspaceOpen", owner: nil)
        }
    }

    /// The window no longer shows the workspace: backends see its context
    /// close, and what they subscribed to in it is disposed.
    func closePluginWorkspaceContext() {
        services.pluginWorkspaceContexts?.close(owner: self)
    }

    /// True while the window's plugin has a new version, a rollback, or an
    /// uninstall waiting for restart: its old page is not shown again.
    func pluginWebPageAwaitsRestart(_ windowID: String) -> Bool {
        guard let pluginID = services.pluginWebPages.windows[windowID]?.pluginID else { return false }
        return pluginSnapshots.first { $0.id.rawValue == pluginID }?.requiresRestart == true
    }

    /// Closes the pages of plugins that are no longer enabled or whose
    /// package changes at the next launch.
    func closeStalePluginWebPages() {
        let pages = services.pluginWebPages
        guard !pages.openWindowIDs.isEmpty else { return }
        let current = Set(pluginSnapshots.filter { $0.isEnabled && !$0.requiresRestart }.map(\.id.rawValue))
        pages.closePages(of: pages.pluginIDs.subtracting(current))
    }
}
