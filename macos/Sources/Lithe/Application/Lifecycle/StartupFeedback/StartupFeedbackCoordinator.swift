import Combine
import Foundation

/// The outcome of a startup, as defined by the shared startup feedback contract.
enum StartupFeedbackOutcome: String, Sendable {
    case idle
    case loading
    case ready
    case failed
}

/// Drives the startup feedback layer.
///
/// The coordinator is a feedback layer only: it never delays the moment the
/// workbench becomes usable. A startup that finishes inside
/// `StartupFeedbackTiming.minimumVisibleDuration` is skipped entirely, a slow
/// startup shows the current phase until the workbench is ready, and a failed
/// startup keeps the failure state on screen until the user dismisses it.
///
/// The clock is created together with the application model, so the reference
/// point for the skip threshold is the application launch rather than the
/// moment the window becomes visible.
@MainActor
final class StartupFeedbackCoordinator: ObservableObject {
    @Published private(set) var outcome: StartupFeedbackOutcome = .idle
    @Published private(set) var stage: StartupStage = .preparing
    @Published private(set) var isVisible = false
    @Published private(set) var isFading = false
    @Published private(set) var isEnabled = true
    @Published private(set) var failureCode: StartupFailureCode?
    @Published private(set) var failureMessage: String?

    private let clock: StartupFeedbackClock
    private let launchTimestamp: TimeInterval
    private var revealToken: StartupFeedbackTimerToken?
    private var fadeOutToken: StartupFeedbackTimerToken?
    /// A readiness report that arrived before the animation started.
    private var isReadyReported = false
    /// A failure report that arrived before the animation started.
    private var pendingFailure: (code: StartupFailureCode, message: String?)?

    init(clock: StartupFeedbackClock = SystemStartupFeedbackClock()) {
        self.clock = clock
        launchTimestamp = clock.now()
    }

    /// Applies the user's startup animation switch.
    ///
    /// A disabled animation shows nothing and never adds waiting time.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled else { return }
        cancelRevealTimer()
        cancelFadeOutTimer()
        isVisible = false
        isFading = false
    }

    /// Starts the feedback.
    ///
    /// Only the first call has an effect: a later session, or a project opened
    /// after the launch, must not replay the startup animation.
    func start() {
        guard isEnabled, outcome == .idle else { return }
        stage = .preparing
        failureCode = nil
        failureMessage = nil
        isVisible = false
        isFading = false

        // The workspace may already be loaded when the window becomes visible.
        // In that case the startup was fast enough and the animation is skipped.
        if isReadyReported {
            outcome = .ready
            return
        }
        if let pendingFailure {
            outcome = .loading
            applyFailure(pendingFailure.code, message: pendingFailure.message)
            return
        }

        outcome = .loading
        cancelRevealTimer()
        cancelFadeOutTimer()
        let remaining = StartupFeedbackTiming.remainingUntilMinimumVisible(elapsedSeconds())
        if remaining <= .zero {
            isVisible = true
            return
        }
        revealToken = clock.schedule(after: remaining) { [weak self] in
            self?.revealTimerFired()
        }
    }

    /// Reports the phase the product is currently working on.
    func setStage(_ stage: StartupStage) {
        guard isEnabled, outcome == .loading else { return }
        self.stage = stage
    }

    /// Marks the startup as finished.
    ///
    /// A startup that finished inside the minimum visible duration is skipped
    /// without showing anything; a slow startup fades the animation out.
    /// Later calls are ignored so a workspace refresh cannot replay it.
    func markReady() {
        isReadyReported = true
        guard outcome == .loading else { return }
        cancelRevealTimer()
        cancelFadeOutTimer()
        outcome = .ready
        guard isEnabled, elapsedSeconds() >= StartupFeedbackTiming.minimumVisibleDurationInSeconds else {
            isVisible = false
            isFading = false
            return
        }
        isVisible = true
        isFading = true
        fadeOutToken = clock.schedule(after: StartupFeedbackTiming.fadeOutDuration) { [weak self] in
            self?.fadeOutTimerFired()
        }
    }

    /// Keeps the failure state on screen so the user can read the reason.
    ///
    /// Only a failure during the launch is reported; a later failure belongs to
    /// the feature that owns it.
    func markFailed(code: StartupFailureCode, message: String?) {
        pendingFailure = (code, message)
        guard outcome == .loading else { return }
        applyFailure(code, message: message)
    }

    /// Dismisses the failure state on user request.
    func dismiss() {
        pendingFailure = nil
        cancelRevealTimer()
        cancelFadeOutTimer()
        isVisible = false
        isFading = false
    }

    /// The time elapsed since the application started.
    private func elapsedSeconds() -> TimeInterval {
        clock.now() - launchTimestamp
    }

    private func applyFailure(_ code: StartupFailureCode, message: String?) {
        cancelRevealTimer()
        cancelFadeOutTimer()
        outcome = .failed
        isVisible = true
        isFading = false
        failureCode = code
        failureMessage = message
    }

    private func revealTimerFired() {
        revealToken = nil
        guard outcome == .loading else { return }
        isVisible = true
    }

    private func fadeOutTimerFired() {
        fadeOutToken = nil
        isVisible = false
        isFading = false
    }

    private func cancelRevealTimer() {
        guard let revealToken else { return }
        clock.cancel(revealToken)
        self.revealToken = nil
    }

    private func cancelFadeOutTimer() {
        guard let fadeOutToken else { return }
        clock.cancel(fadeOutToken)
        self.fadeOutToken = nil
    }
}
