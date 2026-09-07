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
        let java = graph.java
        let spring = graph.spring
        let notification = graph.notification
        let settings = model.settings
        let coordinator = DocumentLanguageCoordinator(
            activate: { [weak model] document in
                _ = model?.activateLanguageServerIfAvailable(for: document)
            },
            reloadProject: { [weak spring, weak session, weak workspace, weak document] changed in
                guard let root = session?.workspaceURL else { return }
                spring?.scheduleReload(
                    changedDocument: changed, workspaceURL: root,
                    files: workspace?.projectFiles ?? [], openDocuments: document?.openDocuments ?? []
                )
            },
            close: { [weak model, weak java] document in
                model?.languageToolingSessionsIfActive?.closeDocument(document.url)
                if java?.handles(fileURL: document.url) == true { java?.close(document) }
            },
            supportsHints: { [weak java] in java?.handles(fileURL: $0.url) == true },
            refreshHints: { [weak model] in await model?.refreshCodeVision(for: $0) }
        )
        graph.languageTooling.configure(
            documentsProvider: { [weak document] in document?.openDocuments ?? [] },
            workspaceProvider: { [weak session] in session?.workspaceURL },
            activateDocument: { [weak model] in model?.activateLanguageServerIfAvailable(for: $0) ?? false },
            notify: { [weak notification] in notification?.show($0) }
        )
        document.configure(
            workspaceURLProvider: { [weak session] in session?.workspaceURL },
            autoSaveEnabledProvider: { [weak settings] in settings?.autoSave ?? false },
            autoSaveDelayProvider: { [weak settings] in settings?.autoSaveDelay ?? 0 },
            notify: { [weak notification] in notification?.show($0) },
            onDocumentOpened: { [weak coordinator] in coordinator?.documentOpened($0) },
            onDocumentChanged: { [weak coordinator] in coordinator?.documentChanged($0) },
            onDocumentClosed: { [weak coordinator] in coordinator?.documentClosed($0) },
            onRecordSave: { [weak model] in model?.recordSave($0, previousText: $1) },
            onRecordDiscard: { [weak model] in model?.recordDiscardedEditorText($0) },
            onRecordExternalChanges: { [weak model] paths in
                model?.withHistoryModule { $0.recordExternalChanges(paths) }
            },
            onDocumentCollectionChanged: { [weak session, weak workspace] in
                guard session?.workspaceURL != nil else { return }
                workspace?.scheduleWorkspaceSessionPersistence()
            },
            onProjectCloseReady: { [weak session] in session?.projectCloseReady() }
        )
        java.configure(
            documentProvider: { [weak document] in document?.activeDocument },
            loadBlame: { [weak model] fileURL in
                guard let feature = await model?.activateGitModule() else { return [] }
                return await feature.loadBlame(for: fileURL)
            }
        )
        return coordinator
    }
}
