import Foundation
import LitheCoreContracts

// Note: 插件自有语言服务器会话与宿主方法的决策见 .agents/notes/implemented/architecture/2026-11-04-plugin-owned-language-server-sessions.md

extension AppModel {
    /// How long a plugin backend may take to produce a document's text.
    private static let pluginContentTimeout: Duration = .seconds(30)

    /// Opens `location` from the plugin content provider that serves its URI
    /// scheme in this window (plan API-12). Returns false when no provider
    /// does, so the caller falls through to the language server path.
    func openFromPluginContentProvider(
        _ location: EditorNavigationLocation,
        recordsHistory: Bool,
        departure: EditorNavigationLocation?,
        onFailure: (() -> Void)?
    ) -> Bool {
        guard !location.url.isFileURL, let scheme = location.url.scheme?.lowercased(),
              let context = pluginWebWorkspaceContext,
              let providers = services.pluginContentProviders,
              let provider = providers.provider(forScheme: scheme, context: context),
              let backends = pluginWebBackends else { return false }
        Task { @MainActor [weak self] in
            do {
                let text = try await Self.pluginContent(of: location.url, from: provider, context: context, backends: backends, providers: providers)
                // The window may have moved on while the plugin was working.
                guard let self, self.pluginWebWorkspaceContext == context,
                      providers.provider(forScheme: scheme, context: context) == provider else { return }
                self.showPluginContent(text, at: location, recordsHistory: recordsHistory, departure: departure)
            // log-exempt: 用户取消：窗口关闭或调用方取消时不代表读取失败
            } catch is CancellationError {
                return
            } catch {
                onFailure?()
                self?.showNotification(
                    error.localizedDescription,
                    logReference: self?.notificationFailure(error, operation: "plugin_content_provider")
                )
            }
        }
        return true
    }

    /// Asks the provider's function for the document and has Core check the answer.
    private static func pluginContent(
        of url: URL,
        from provider: PluginContentProviderRegistration,
        context: PluginWorkspaceContextReference,
        backends: any PluginBackendRequesting,
        providers: PluginContentProviderHostService
    ) async throws -> String {
        let answer = try await backends.invokePluginFunction(
            provider.functionID,
            params: .object(["uri": .string(url.absoluteString)]),
            ofPlugin: provider.pluginID,
            context: context,
            timeout: pluginContentTimeout,
            progress: { _ in }
        )
        return try providers.content(of: answer)
    }

    /// Opens the text read-only and moves to the target, like any virtual document.
    private func showPluginContent(
        _ text: String,
        at location: EditorNavigationLocation,
        recordsHistory: Bool,
        departure: EditorNavigationLocation?
    ) {
        if recordsHistory { navigationHistoryFeature.recordJump(from: departure, to: location) }
        editorTabOrderFeature.repositoryDiffSelected = false
        documentFeature.openVirtualDocument(location.url, text: text, displayPath: location.displayPath)
        editorNavigationTarget = EditorNavigationTarget(
            url: location.url.standardizedFileURL,
            line: location.line,
            utf16Column: location.utf16Column,
            selectsWholeLine: location.selectsWholeLine
        )
    }
}
