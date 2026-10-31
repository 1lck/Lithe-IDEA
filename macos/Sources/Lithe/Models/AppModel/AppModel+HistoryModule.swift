import Combine
import Foundation
import LitheLocalHistoryModule

@MainActor
extension AppModel {
    var projectHistoryFeatureIfActive: ProjectHistoryFeatureModel? {
        historyCapability?.feature
    }

    func activateHistoryModule() async -> ProjectHistoryFeatureModel? {
        await historyModuleCoordinator.activate()
    }

    func localHistoryIgnorePreview(path: String?, rules: LocalHistoryVisibilityRules) async -> LocalHistoryIgnorePreview? {
        await activateHistoryModule()?.previewIgnoreRules(path: path, rules: rules)
    }

    /// Nil when no project is open.
    func localHistoryUsage() async -> LocalHistoryUsage? {
        guard workspaceURL != nil else { return nil }
        return await activateHistoryModule()?.storageUsage()
    }

    func clearLocalHistory() async -> Bool {
        guard workspaceURL != nil, let feature = await activateHistoryModule() else { return false }
        return await feature.clearHistory()
    }

    func withHistoryModule(_ action: @escaping @MainActor (ProjectHistoryFeatureModel) async -> Void) {
        historyModuleCoordinator.perform(action)
    }

    func loadExternalVersion(of document: EditorDocument) {
        documentFeature.loadExternalVersion(of: document)
    }

    func keepEditorVersion(of document: EditorDocument) {
        documentFeature.keepEditorVersion(of: document)
    }

    func relativePath(for url: URL) -> String {
        guard let workspaceURL else { return url.lastPathComponent }
        return workspaceRelativePath(for: url, root: workspaceURL) ?? url.lastPathComponent
    }

    func recordSave(_ document: EditorDocument, previousText: String) {
        let snapshot = LocalHistoryDocumentSnapshot(id: document.id, url: document.url, text: document.text)
        withHistoryModule { $0.recordSave(snapshot, previousText: previousText) }
    }

    func recordDiscardedEditorText(_ document: EditorDocument) {
        let snapshot = LocalHistoryDocumentSnapshot(id: document.id, url: document.url, text: document.text)
        withHistoryModule { $0.recordDiscardedEditorText(snapshot) }
    }
}
