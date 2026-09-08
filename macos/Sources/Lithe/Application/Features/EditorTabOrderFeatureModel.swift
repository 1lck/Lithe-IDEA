import Combine
import Foundation

/// Owns only the mixed presentation order of document and terminal tabs.
/// Resource lifecycle and active selection remain with their existing features.
@MainActor
final class EditorTabOrderFeatureModel: ObservableObject {
    @Published private(set) var items: [EditorTabItem] = []

    var documentIDs: [UUID] {
        items.compactMap {
            guard case .document(let id) = $0 else { return nil }
            return id
        }
    }

    var mediaIDs: [UUID] {
        items.compactMap {
            guard case .media(let id) = $0 else { return nil }
            return id
        }
    }

    var terminalIDs: [UUID] {
        items.compactMap {
            guard case .terminal(let id) = $0 else { return nil }
            return id
        }
    }

    func contains(_ item: EditorTabItem) -> Bool {
        items.contains(item)
    }

    func moveToEnd(_ item: EditorTabItem) {
        var next = items
        next.removeAll { $0 == item }
        next.append(item)
        guard next != items else { return }
        items = next
    }

    func remove(_ item: EditorTabItem) {
        items.removeAll { $0 == item }
    }

    func removeAllTerminals() {
        items.removeAll {
            guard case .terminal = $0 else { return false }
            return true
        }
    }

    @discardableResult
    func move(_ item: EditorTabItem, before target: EditorTabItem) -> Bool {
        move(item, relativeTo: target, insertAfter: false)
    }

    @discardableResult
    func move(_ item: EditorTabItem, after target: EditorTabItem) -> Bool {
        move(item, relativeTo: target, insertAfter: true)
    }

    /// Reconciles document membership and relative order while leaving terminal
    /// slots untouched. This lets the document feature remain the resource owner.
    func reconcileDocuments(orderedIDs: [UUID]) {
        let openDocumentIDs = Set(orderedIDs)
        let representedDocumentIDs = Set(documentIDs)
        let reorderedExistingIDs = orderedIDs.filter { representedDocumentIDs.contains($0) }
        var existingIndex = 0
        var next: [EditorTabItem] = []

        for item in items {
            switch item {
            case .document(let id):
                guard openDocumentIDs.contains(id),
                      reorderedExistingIDs.indices.contains(existingIndex) else { continue }
                next.append(.document(reorderedExistingIDs[existingIndex]))
                existingIndex += 1
            case .terminal, .media:
                next.append(item)
            }
        }

        let alreadyRepresented = Set(reorderedExistingIDs)
        next.append(contentsOf: orderedIDs.compactMap { id in
            alreadyRepresented.contains(id) ? nil : .document(id)
        })

        guard next != items else { return }
        items = next
    }

    /// Reconciles media membership while preserving the mixed tab slots.
    func reconcileMedia(orderedIDs: [UUID]) {
        let openMediaIDs = Set(orderedIDs)
        let representedMediaIDs = Set(mediaIDs)
        let reorderedExistingIDs = orderedIDs.filter { representedMediaIDs.contains($0) }
        var existingIndex = 0
        var next: [EditorTabItem] = []

        for item in items {
            switch item {
            case .media(let id):
                guard openMediaIDs.contains(id),
                      reorderedExistingIDs.indices.contains(existingIndex) else { continue }
                next.append(.media(reorderedExistingIDs[existingIndex]))
                existingIndex += 1
            default:
                next.append(item)
            }
        }

        let alreadyRepresented = Set(reorderedExistingIDs)
        next.append(contentsOf: orderedIDs.compactMap { id in
            alreadyRepresented.contains(id) ? nil : .media(id)
        })

        guard next != items else { return }
        items = next
    }

    private func move(
        _ item: EditorTabItem,
        relativeTo target: EditorTabItem,
        insertAfter: Bool
    ) -> Bool {
        guard item != target, items.contains(target) else { return false }
        var next = items
        next.removeAll { $0 == item }
        guard let targetIndex = next.firstIndex(of: target) else { return false }
        next.insert(item, at: targetIndex + (insertAfter ? 1 : 0))
        guard next != items else { return false }
        items = next
        return true
    }
}
