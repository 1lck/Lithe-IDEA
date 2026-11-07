import Foundation
import LitheLanguageIntelligenceModule

/// Wires document ports to session, language, history, and notification owners.
@MainActor
enum DocumentFeatureComposition {
    static func configure(model: AppModel) -> DocumentLanguageCoordinator {
        let graph = model.featureGraph
        let document = graph.document
        let workspace = graph.workspace
        let session = graph.workspaceSession
        let notification = graph.notification
        let settings = model.settings
        let coordinator = DocumentLanguageCoordinator(
            activate: { [weak model] document in
                _ = model?.activateLanguageServerIfAvailable(for: document)
            },
            // Project indexes and inline hints come from language plugins
            // through their language servers; the host keeps no per-language index.
            reloadProject: { _ in },
            close: { [weak model] document in
                model?.languageToolingSessionsIfActive?.closeDocument(document.url)
            },
            supportsHints: { _ in false },
            refreshHints: { _ in }
        )
        graph.languageTooling.logSink = model.services.logSink
        graph.languageTooling.notifyLog = { [weak notification] in notification?.show($0, logReference: $1) }
        graph.languageTooling.configure(
            documentsProvider: { [weak document] in document?.openDocuments ?? [] },
            activateDocument: { [weak model] in model?.activateLanguageServerIfAvailable(for: $0) ?? false },
            notify: { [weak notification] in notification?.show($0) }
        )
        document.notifyWithLog = { [weak notification] in notification?.show($0, logReference: $1) }
        document.configure(
            workspaceURLProvider: { [weak session] in session?.workspaceURL },
            autoSaveEnabledProvider: { [weak settings] in settings?.autoSave ?? false },
            autoSaveDelayProvider: { [weak settings] in settings?.autoSaveDelay ?? 0 },
            notify: { [weak notification] in notification?.show($0) },
            onDocumentOpened: { [weak coordinator] in coordinator?.documentOpened($0) },
            onDocumentChanged: { [weak coordinator] in coordinator?.documentChanged($0) },
            onDocumentClosed: { [weak coordinator] in coordinator?.documentClosed($0) },
            onRecordSave: { [weak model] document, previousText in
                guard let model else { return }
                model.recordSave(document, previousText: previousText)
                do {
                    try model.languageToolingSessionsIfActive?.notifyDocumentSaved(
                        document.url, text: document.savedText, currentText: document.text)
                } catch {
                    model.showNotification(error.localizedDescription, logReference: model.notificationFailure(error, operation: "document_saved_notification"))
                }
            },
            onRecordDiscard: { [weak model] in model?.recordDiscardedEditorText($0) },
            onRecordExternalChanges: { [weak model] paths in
                model?.withHistoryModule { $0.recordExternalChanges(paths) }
            },
            onDocumentCollectionChanged: { [weak session, weak workspace] in
                guard session?.workspaceURL != nil else { return }
                workspace?.scheduleWorkspaceSessionPersistence()
            },
            onProjectCloseReady: { [weak session] in session?.projectCloseReady() },
            onCloseFailed: { [weak session] in session?.cancelPendingClose() }
        )
        return coordinator
    }
}
