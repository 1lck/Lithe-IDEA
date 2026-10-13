import Foundation

// Group changes synchronize the existing document before committing tab placement.
extension AppModel {
    func moveEditorTab(_ item: EditorTabItem, toGroup group: UUID, side: EditorGroupDropSide) {
        let requestID = UUID()
        editorTabOrderFeature.groupDropRequestID = requestID
        let layout = editorTabOrderFeature.groupLayout
        let commit: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, self.editorTabOrderFeature.groupDropRequestID == requestID,
                  self.editorTabOrderFeature.groupLayout == layout,
                  !self.documentFeature.hasPendingDocumentClose,
                  self.editorTabOrderFeature.contains(item) else { return }
            guard case .success = result else {
                self.showNotification(String(localized: "Could not move the editor tab. Its content could not be synchronized."))
                return
            }
            if self.editorTabOrderFeature.drop(item, into: group, side: side) { self.selectEditorTab(item) }
        }
        if case .document(let id) = item, let document = openDocuments.first(where: { $0.id == id }) {
            document.withSynchronizedEditor(commit)
        } else { commit(.success(())) }
    }
}
