import Foundation

/// Request identity is independent of the bridge's cached document references.
/// A callback can keep a closed document alive, and a rename need not edit text.
@MainActor
struct MonacoDocumentContext {
    let documentID: UUID
    let url: URL
    let locationRevision: UInt64
    let revision: Int
    let workspaceURL: URL?

    init(document: EditorDocument, revision: Int, workspaceURL: URL?) {
        documentID = document.id
        url = document.url
        locationRevision = document.locationRevision
        self.revision = revision
        self.workspaceURL = workspaceURL
    }

    func matchesIdentity(document: EditorDocument, documents: [EditorDocument], workspaceURL: URL?) -> Bool {
        document.id == documentID && document.url == url && document.locationRevision == locationRevision
            && self.workspaceURL == workspaceURL && documents.contains { $0 === document }
    }

    func matches(document: EditorDocument, revision: Int?, documents: [EditorDocument], workspaceURL: URL?) -> Bool {
        self.revision == revision && matchesIdentity(document: document, documents: documents, workspaceURL: workspaceURL)
    }
}
