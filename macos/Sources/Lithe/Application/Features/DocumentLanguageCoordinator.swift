import Foundation

/// Owns document-triggered language actions and the lifetime of delayed hints.
@MainActor
final class DocumentLanguageCoordinator {
    private struct Refresh {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let activate: (EditorDocument) -> Void
    private let reloadProject: (EditorDocument) -> Void
    private let close: (EditorDocument) -> Void
    private let supportsHints: (EditorDocument) -> Bool
    private let refreshHints: (URL) async -> Void
    private let delay: @Sendable (Duration) async throws -> Void
    private var refreshes: [UUID: Refresh] = [:]

    init(
        activate: @escaping (EditorDocument) -> Void,
        reloadProject: @escaping (EditorDocument) -> Void,
        close: @escaping (EditorDocument) -> Void,
        supportsHints: @escaping (EditorDocument) -> Bool,
        refreshHints: @escaping (URL) async -> Void,
        delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.activate = activate
        self.reloadProject = reloadProject
        self.close = close
        self.supportsHints = supportsHints
        self.refreshHints = refreshHints
        self.delay = delay
    }

    func documentOpened(_ document: EditorDocument) {
        activate(document)
        scheduleHints(for: document, after: .zero)
    }

    func documentChanged(_ document: EditorDocument) {
        activate(document)
        reloadProject(document)
        scheduleHints(for: document, after: .milliseconds(450))
    }

    func documentClosed(_ document: EditorDocument) {
        refreshes.removeValue(forKey: document.id)?.task.cancel()
        close(document)
    }

    func stop() {
        refreshes.values.forEach { $0.task.cancel() }
        refreshes.removeAll()
    }

    private func scheduleHints(for document: EditorDocument, after duration: Duration) {
        refreshes.removeValue(forKey: document.id)?.task.cancel()
        guard supportsHints(document) else { return }
        let id = UUID()
        let documentID = document.id
        let task = Task { @MainActor [weak self, weak document, delay] in
            if duration > .zero {
                do { try await delay(duration) }
                catch { return }
            }
            guard !Task.isCancelled, let self, let document,
                  self.refreshes[documentID]?.id == id else { return }
            await self.refreshHints(document.url)
            if self.refreshes[documentID]?.id == id {
                self.refreshes.removeValue(forKey: documentID)
            }
        }
        refreshes[documentID] = Refresh(id: id, task: task)
    }

    deinit {
        refreshes.values.forEach { $0.task.cancel() }
    }
}
