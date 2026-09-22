import Foundation

/// Publishes the newest Debug Console snapshot at a bounded cadence.
///
/// DAP and integrated-terminal output can arrive as thousands of small chunks.
/// The feature model keeps the complete value synchronously for diagnostics and
/// session snapshots, while this object limits expensive SwiftUI/AppKit updates
/// to one per short batch.
@MainActor
public final class GenericDebugOutputPresentation: ObservableObject {
    @Published public private(set) var text: String

    private let flushDelay: Duration
    private var pendingSnapshot: (@MainActor () -> String)?
    private var flushTask: Task<Void, Never>?

    init(
        text: String = "",
        flushDelay: Duration = .milliseconds(100)
    ) {
        self.text = text
        self.flushDelay = flushDelay
    }

    func schedule(_ snapshot: @escaping @MainActor () -> String) {
        pendingSnapshot = snapshot
        guard flushTask == nil else { return }
        let flushDelay = flushDelay
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: flushDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Replaces the visible session immediately and discards an obsolete batch.
    func replace(with text: String) {
        flushTask?.cancel()
        flushTask = nil
        pendingSnapshot = nil
        self.text = text
    }

    /// Exposed internally so lifecycle code and deterministic tests can drain.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard let pendingSnapshot else { return }
        self.pendingSnapshot = nil
        text = pendingSnapshot()
    }

    isolated deinit {
        flushTask?.cancel()
    }
}
