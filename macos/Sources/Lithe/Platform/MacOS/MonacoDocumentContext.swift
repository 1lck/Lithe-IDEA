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

/// Workspace edits can target open buffers that have never had a Monaco view.
/// Their native revisions must be captured before asking the language server.
@MainActor
struct MonacoWorkspaceContext {
    private let workspaceURL: URL?
    private var snapshots: [UUID: (url: URL, location: UInt64, revision: UInt64)] = [:]

    init(documents: [EditorDocument], workspaceURL: URL?) {
        self.workspaceURL = workspaceURL
        for document in documents {
            snapshots[document.id] = (document.url, document.locationRevision, document.lifecycleState.revision)
        }
    }

    func matches(documents: [EditorDocument], workspaceURL: URL?) -> Bool {
        guard self.workspaceURL == workspaceURL else { return false }
        return snapshots.allSatisfy { id, snapshot in
            guard let document = documents.first(where: { $0.id == id }) else { return false }
            return document.url == snapshot.url && document.locationRevision == snapshot.location
                && document.lifecycleState.revision == snapshot.revision
        }
    }
}
