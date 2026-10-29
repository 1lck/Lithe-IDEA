import Foundation
import LitheCoreContracts

extension AppModel {
    /// Document/editor service bound to this window. The plugin dispatch layer
    /// creates one per window and passes the caller's scope on every call.
    func makeEditorDocumentService() -> EditorDocumentService {
        EditorDocumentService(
            windowID: id,
            workspaceURL: { [weak self] in self?.workspaceURL },
            documents: { [weak self] in self?.documentFeature.editorDocuments ?? [] },
            activeDocumentID: { [weak self] in self?.documentFeature.activeDocumentID },
            languageIdentifier: { [weak self] url in
                self?.languageProviderCatalog.provider(for: url)?.languageIdentifier(for: url)
            })
    }
}
