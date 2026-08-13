import Combine
import Foundation

/// Coordinates source navigation as a transaction. A target is published only
/// after its document is active, so the editor never tries to reveal a range in
/// a view that is about to be replaced.
@MainActor
final class EditorNavigationFeatureModel: ObservableObject {
    @Published private(set) var target: EditorNavigationTarget?
    @Published private(set) var isNavigating = false

    private var transactionTask: Task<Void, Never>?
    private var transactionRevision: UInt64 = 0

    func navigate(
        to target: EditorNavigationTarget,
        activateDocument: @escaping @MainActor () async -> Bool
    ) {
        transactionTask?.cancel()
        transactionRevision &+= 1
        let revision = transactionRevision
        isNavigating = true

        transactionTask = Task { @MainActor [weak self] in
            let didActivate = await activateDocument()
            guard let self,
                  !Task.isCancelled,
                  self.transactionRevision == revision else { return }
            self.isNavigating = false
            guard didActivate else { return }
            self.target = target
        }
    }

    /// Used for virtual documents that are resolved through a provider callback
    /// and are already active by the time their content reaches the application.
    func reveal(_ target: EditorNavigationTarget) {
        transactionTask?.cancel()
        transactionRevision &+= 1
        isNavigating = false
        self.target = target
    }

    func reset() {
        transactionTask?.cancel()
        transactionTask = nil
        transactionRevision &+= 1
        isNavigating = false
        target = nil
    }
}
