import Foundation

/// Timing thresholds owned by the shared startup feedback contract.
///
/// The animation is a feedback layer: it never delays the moment the workbench
/// becomes usable. A startup that finishes within `minimumVisibleDuration` is
/// skipped entirely, so a fast launch never flashes an animation.
enum StartupFeedbackTiming {
    /// A startup faster than this window never shows the animation.
    static let minimumVisibleDuration: Duration = .milliseconds(400)
    /// How long the animation takes to fade out once the workbench is ready.
    static let fadeOutDuration: Duration = .milliseconds(180)

    /// The skip threshold in seconds, for APIs that take a `TimeInterval`.
    static var minimumVisibleDurationInSeconds: TimeInterval {
        minimumVisibleDuration.secondsValue
    }

    /// The fade-out duration in seconds, for APIs that take a `TimeInterval`.
    static var fadeOutDurationInSeconds: TimeInterval {
        fadeOutDuration.secondsValue
    }

    /// How much of the skip threshold is still left after `elapsed` seconds.
    ///
    /// The threshold is measured from the application launch, so a window that
    /// becomes visible late does not restart the wait.
    static func remainingUntilMinimumVisible(elapsed: TimeInterval) -> Duration {
        let remaining = minimumVisibleDurationInSeconds - elapsed
        guard remaining > 0 else { return .zero }
        return .milliseconds(Int64((remaining * 1000).rounded(.up)))
    }
}

extension Duration {
    /// The duration expressed as a `TimeInterval`.
    var secondsValue: TimeInterval {
        let components = self.components
        return components.seconds + Double(components.attoseconds) / 1e18
    }
}
