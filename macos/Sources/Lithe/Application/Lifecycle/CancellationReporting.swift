import Foundation

extension Error {
    /// Whether this failure only reports that the current operation was
    /// cancelled, either by the user or because the session or module graph was
    /// torn down mid-activation. Such outcomes are expected and must not be
    /// surfaced as failure notifications; every other error still is.
    ///
    /// `Task.isCancelled` is checked as well because cancelled work can surface
    /// a secondary error (for example `URLError.cancelled`) instead of
    /// `CancellationError`.
    var isCancellation: Bool {
        self is CancellationError || Task.isCancelled
    }
}
