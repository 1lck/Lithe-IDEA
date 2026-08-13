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
    private var backStack: [EditorNavigationTarget] = []
    private var forwardStack: [EditorNavigationTarget] = []
    private let historyLimit = 100

    var canNavigateBack: Bool { !backStack.isEmpty }
    var canNavigateForward: Bool { !forwardStack.isEmpty }

    func navigate(
        to target: EditorNavigationTarget,
        from source: EditorNavigationTarget? = nil,
        recordsHistory: Bool = true,
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
            if recordsHistory, let source, !Self.samePosition(source, target) {
                self.backStack.append(source)
                if self.backStack.count > self.historyLimit {
                    self.backStack.removeFirst(self.backStack.count - self.historyLimit)
                }
                self.forwardStack.removeAll(keepingCapacity: true)
            }
            self.target = target
        }
    }

    func takeBackDestination(from current: EditorNavigationTarget?) -> EditorNavigationTarget? {
        guard let destination = backStack.popLast() else { return nil }
        if let current, !Self.samePosition(current, destination) {
            forwardStack.append(current)
        }
        objectWillChange.send()
        return destination
    }

    func takeForwardDestination(from current: EditorNavigationTarget?) -> EditorNavigationTarget? {
        guard let destination = forwardStack.popLast() else { return nil }
        if let current, !Self.samePosition(current, destination) {
            backStack.append(current)
        }
        objectWillChange.send()
        return destination
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
        backStack = []
        forwardStack = []
    }

    private static func samePosition(
        _ lhs: EditorNavigationTarget,
        _ rhs: EditorNavigationTarget
    ) -> Bool {
        lhs.url.standardizedFileURL == rhs.url.standardizedFileURL
            && lhs.range.start == rhs.range.start
    }
}
