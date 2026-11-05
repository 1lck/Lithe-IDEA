import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Links in the Run and test consoles that enabled plugins declared matchers for.
@MainActor
extension AppModel {
    func pluginOutputLinkMarks(in text: String, scope: PluginOutputLinkService.Scope,
                               searchRoots: [URL]) -> [PluginOutputLinkService.Mark] {
        services.pluginOutputLinks?.marks(
            in: text, scope: scope, workspaceRoots: searchRoots, fileExists: { fileExists(at: $0) }) ?? []
    }

    /// The user clicked a link only the plugin can place. The plugin answers; the window opens
    /// the file it named, or says that none was found.
    func openPluginOutputLink(_ url: URL) {
        guard let question = PluginOutputLinkService.Question(url: url) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let location = await resolvePluginOutputLink(question)
            let opened = location.map { pluginWebOpenFile(URL(fileURLWithPath: $0.path), line: $0.line, column: $0.column) }
            if opened != true { showNotification(L10n.string("The plugin could not find a file for this link.")) }
        }
    }

    private func resolvePluginOutputLink(_ question: PluginOutputLinkService.Question) async -> PluginOutputLinkLocation? {
        guard let service = services.pluginOutputLinks, let backends = pluginWebBackends else { return nil }
        do {
            return try await service.location(answering: question, backends: backends, context: pluginWebWorkspaceContext)
        } catch {
            if let plugin = LogSegment(question.pluginID) {
                services.logSink?.emit(PluginsHostRequestFailed(error: error, plugin: plugin))
            }
            return nil
        }
    }
}
