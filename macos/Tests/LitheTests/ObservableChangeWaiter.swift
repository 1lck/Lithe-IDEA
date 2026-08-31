import Combine
import Foundation

/// Awaits an observable publication with a local deadline. Feature models
/// publish from tasks they own, so a test cannot observe completion
/// synchronously, and a poll loop would depend on machine speed.
///
/// Returns `false` when the deadline elapses first so the caller can turn the
/// timeout into an assertion instead of hanging until the CI job is killed. The
/// deadline is only paid by a failing test, so it stays well inside the timing
/// harness budget.
@MainActor
func awaitChange<Model: ObservableObject>(
    on model: Model,
    timeout: DispatchTimeInterval = .seconds(5),
    until isSatisfied: @escaping @MainActor @Sendable () -> Bool
) async -> Bool where Model.ObjectWillChangePublisher == ObservableObjectPublisher {
    if isSatisfied() { return true }
    return await withCheckedContinuation { continuation in
        let resumption = SingleResumption(continuation)
        // objectWillChange fires before each assignment, so the predicate runs
        // on the following main-actor turn, once the publication has completed.
        resumption.observe(model.objectWillChange.sink { _ in
            Task { @MainActor in
                guard isSatisfied() else { return }
                resumption.finish(with: true)
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            resumption.finish(with: false)
        }
    }
}

/// The observation and the deadline race for a continuation that may only be
/// resumed once. Both arms run on the main thread.
private final class SingleResumption: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observation: AnyCancellable?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func observe(_ observation: AnyCancellable) {
        guard continuation != nil else {
            observation.cancel()
            return
        }
        self.observation = observation
    }

    func finish(with value: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        observation?.cancel()
        observation = nil
        pending.resume(returning: value)
    }
}
