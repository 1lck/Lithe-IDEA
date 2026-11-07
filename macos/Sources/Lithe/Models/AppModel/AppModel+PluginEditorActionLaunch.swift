import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Toolbar Run and Debug for a language whose package exposes execution only
/// as editor actions (`RunWorkflowCoordinator.languageSupportRoutingToEditorActions`).
///
/// The host collects the active document's actions exactly as the gutter does
/// and calls the plugin's own function for the one drawn as `run`/`debug`.
/// Whether anything starts remains the plugin's decision; a run or debug
/// session it opens through the host methods appears in the tool windows the
/// same way a gutter click would.
@MainActor
extension AppModel {
    /// The collector for the local workspace this window shows; nil when
    /// plugin editor actions are not served here (remote workspace, no service).
    var pluginEditorActionCollector: PluginEditorActionCollector? {
        guard let workspace = pluginWebWorkspaceContext,
              services.pluginWorkspaceContexts?.contexts.contains(where: { $0.reference == workspace && $0.authority == .local }) == true,
              let service = services.pluginEditorActions, let backends = pluginWebBackends else { return nil }
        return PluginEditorActionCollector(service: service, backends: backends, workspace: workspace, logSink: services.logSink)
    }

    /// Starts `intent` for `document` through the owning package's editor
    /// action, or tells the user why nothing could start.
    func startPluginEditorAction(
        _ intent: PluginEditorActionIntent, document: EditorDocument,
        support: LanguageSupportDeclaration, identity: WorkspaceIdentity
    ) async {
        let unavailable: () -> Void = { [weak self] in
            guard let self else { return }
            let key = intent == .run ? "%@ does not provide project execution" : "%@ does not provide debugging"
            let reason = intent == .run ? "run_editor_action_unavailable" : "debug_editor_action_unavailable"
            showNotification(key, arguments: [support.displayName],
                             logReference: notificationRejection(operation: "run_workflow", reason: reason))
        }
        guard let collector = pluginEditorActionCollector,
              PluginEditorActionCollector.admits(document, service: collector.service) else { return unavailable() }
        let registrations = collector.registrations(for: document)
        guard !registrations.isEmpty else { return unavailable() }
        let documentID = document.id.uuidString, version = document.contentVersion
        let path = PluginEditorActionCollector.workspaceRelativePath(of: document.url, root: workspaceURL)
        let items: [PluginEditorActionItem]
        do {
            items = try await collector.collect(documentID: documentID, version: version, path: path,
                                                text: document.text, registrations: registrations)
        } catch { return } // log-exempt: collect 只在取消时抛出，其它插件失败已由收集器记录 PluginsEditorActionsFailed
        guard isCurrentWorkspace(identity), !Task.isCancelled else { return }
        guard document.contentVersion == version, collector.stillRegistered(items) else {
            showNotification("The file changed while preparing to start. Try again.",
                             logReference: notificationRejection(operation: "run_workflow", reason: "editor_action_stale"))
            return
        }
        guard let choice = PluginEditorActionLaunchSelection.choose(items, intent: intent) else { return unavailable() }
        let operation = UUID()
        do {
            if let reveal = try await collector.invoke(choice, documentID: documentID, expectedVersion: version) {
                revealPluginLocations(reveal)
            }
        } catch is CancellationError { // log-exempt: 用户取消或切换工作区不是失败，不需要记录
            return
        } catch {
            var reference: LogRecordReference?
            if let plugin = LogSegment(choice.item.registration.pluginID) {
                let event = PluginsEditorActionFailed(error: error, plugin: plugin, operationID: operation.uuidString)
                services.logSink?.emit(event)
                reference = event.reference
            }
            showNotification("The plugin host request could not be completed.", logReference: reference)
        }
    }
}
