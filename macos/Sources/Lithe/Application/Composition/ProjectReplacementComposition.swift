import Foundation
import LitheLocalHistoryModule
import LitheSearchModule

@MainActor
enum ProjectReplacementComposition {
    static func make(model: AppModel) -> ProjectReplacementCoordinator {
        ProjectReplacementCoordinator(
            session: model.searchSessionFeature,
            activate: { [weak model] in await model?.activateSearchModule() },
            workspace: { [weak model] in model?.workspaceURL },
            paths: { [weak model] root in
                model?.projectFiles.compactMap { model?.workspaceRelativePath(for: $0, root: root) } ?? []
            },
            overrides: { [weak model] root in model?.openDocumentTextOverrides(rootURL: root) ?? [:] },
            visibilityRules: { [weak model] in
                model?.settings.fileVisibilityRules.searchRules
                    ?? SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
            },
            recordHistory: { [weak model] text, url in
                guard let feature = await model?.activateHistoryModule() else { return }
                await feature.recordHistorySnapshot(text: text, for: url, reason: .beforeBatchReplace)
            },
            saveOverride: { [weak model] url, text in
                guard let model,
                      let document = model.openDocuments.first(where: {
                          $0.url.standardizedFileURL == url.standardizedFileURL
                      }) else { return false }
                let previousText = document.text
                document.text = text
                do { try model.saveDocument(document); return true }
                catch { document.text = previousText; throw error }
            },
            refreshWorkspace: { [weak model] in await model?.refreshWorkspace() },
            markIdle: { [weak model] in try? model?.services.moduleRuntime.markIdle(.search) },
            notify: { [weak model] in model?.showNotification($0) }
        )
    }
}
