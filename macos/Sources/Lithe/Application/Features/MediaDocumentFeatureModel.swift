import Combine
import Foundation

/// Owns the lifecycle of read-only image and video resources shown as editor tabs.
@MainActor
final class MediaDocumentFeatureModel: ObservableObject {
    @Published private(set) var openMediaDocuments: [MediaDocument] = []
    @Published private(set) var activeMediaDocumentID: UUID?

    var activeMediaDocument: MediaDocument? {
        guard let activeMediaDocumentID else { return nil }
        return openMediaDocuments.first { $0.id == activeMediaDocumentID }
    }

    @discardableResult
    func open(
        url: URL,
        kind: MediaDocumentKind,
        activateWhenReady: Bool = true
    ) -> MediaDocument {
        let normalizedURL = url.standardizedFileURL
        if let existing = openMediaDocuments.first(where: {
            $0.url.standardizedFileURL.path == normalizedURL.path
        }) {
            if activateWhenReady {
                activeMediaDocumentID = existing.id
            }
            return existing
        }

        let document = MediaDocument(url: normalizedURL, kind: kind)
        openMediaDocuments.append(document)
        if activateWhenReady {
            activeMediaDocumentID = document.id
        }
        return document
    }

    func deactivate() {
        guard activeMediaDocumentID != nil else { return }
        activeMediaDocumentID = nil
    }

    func select(_ document: MediaDocument) {
        guard openMediaDocuments.contains(where: { $0.id == document.id }) else { return }
        activeMediaDocumentID = document.id
    }

    func close(_ document: MediaDocument) {
        guard let index = openMediaDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        let wasActive = activeMediaDocumentID == document.id
        openMediaDocuments.remove(at: index)
        guard wasActive else { return }
        if openMediaDocuments.indices.contains(index) {
            activeMediaDocumentID = openMediaDocuments[index].id
        } else {
            activeMediaDocumentID = openMediaDocuments.last?.id
        }
    }

    func reset() {
        openMediaDocuments = []
        activeMediaDocumentID = nil
    }
}
