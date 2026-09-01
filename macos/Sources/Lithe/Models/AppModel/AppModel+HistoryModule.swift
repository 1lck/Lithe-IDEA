import Combine
import Foundation
import LitheLocalHistoryModule

@MainActor
extension AppModel {
    var projectHistoryFeatureIfActive: ProjectHistoryFeatureModel? {
        historyCapability?.feature
    }

    func activateHistoryModule() async -> ProjectHistoryFeatureModel? {
        if let feature = projectHistoryFeatureIfActive { return feature }
        do {
            let value = try await services.moduleRuntime.activateCapability(.historyWorkspace)
            guard let capability = value as? LitheLocalHistoryModule.HistoryModuleCapability else { return nil }
            cacheModuleCapability(capability, id: .historyWorkspace, moduleID: .localHistory)
            let feature = capability.feature
            feature.configure(
                workspaceURLProvider: { [weak self] in self?.workspaceURL },
                projectFilesProvider: { [weak self] in self?.projectFiles ?? [] },
                documentsProvider: { [weak self] in
                    self?.openDocuments.map {
                        LocalHistoryDocumentSnapshot(id: $0.id, url: $0.url, text: $0.text)
                    } ?? []
                }
            )
            if let workspaceURL {
                feature.openWorkspace(
                    at: workspaceURL,
                    visibilityRules: settings.fileVisibilityRules.localHistoryRules
                )
            }
            observeModuleFeature(.localHistory, observation: feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return feature
        } catch {
            return nil
        }
    }

    func withHistoryModule(_ action: @escaping @MainActor (ProjectHistoryFeatureModel) async -> Void) {
        Task { @MainActor [weak self] in
            guard let self, let feature = await self.activateHistoryModule() else { return }
            await action(feature)
        }
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
