import Foundation

/// Identifies a scheduled startup feedback action so it can be cancelled.
struct StartupFeedbackTimerToken: Hashable, Sendable {
    let id: UInt64
}

/// The time source of the startup feedback.
///
/// The coordinator never reads the wall clock on its own, so a test can drive
/// the skip threshold, the fade-out, and the failure state with a deterministic
/// clock instead of waiting in real time.
@MainActor
protocol StartupFeedbackClock: AnyObject {
    /// Monotonic seconds used to measure how long the startup takes.
    func now() -> TimeInterval
    /// Schedules `action` after `delay` and returns the token that cancels it.
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> StartupFeedbackTimerToken
    /// Cancels a scheduled action.
    func cancel(_ token: StartupFeedbackTimerToken)
}

/// The clock used by the running application.
@MainActor
final class SystemStartupFeedbackClock: StartupFeedbackClock {
    private var nextToken: UInt64 = 0
    private var tasks: [StartupFeedbackTimerToken: Task<Void, Never>] = [:]

    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> StartupFeedbackTimerToken {
        nextToken += 1
        let token = StartupFeedbackTimerToken(id: nextToken)
        // The task inherits the main actor of this clock, so the scheduled
        // action always reaches the coordinator on the main thread.
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.tasks[token] = nil
            action()
        }
        tasks[token] = task
        return token
    }

    func cancel(_ token: StartupFeedbackTimerToken) {
        tasks.removeValue(forKey: token)?.cancel()
    }
}
