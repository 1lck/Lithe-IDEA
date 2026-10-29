import Combine
import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheModuleAPI

/// Keeps the one-shot form alive through the bounded DAP initialization, not
/// just the synchronous launch call. Cancellation only owns this attempt's session.
@MainActor
enum ExternalDebugAdapterConnection {
    static func connect(
        feature: GenericDebugFeatureModel, fileURL: URL, rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard !feature.isSessionActive else {
            return L10n.string("Stop the current debug session before connecting to a debug adapter.")
        }
        guard feature.start(fileURL: fileURL, rootURL: rootURL, configuration: configuration),
              let sessionID = feature.activeSessionID else {
            return feature.errorMessage ?? L10n.string("The debug adapter connection could not be started.")
        }
        return await Attempt(feature: feature, sessionID: sessionID).wait()
    }

    @MainActor
    private final class Attempt {
        let feature: GenericDebugFeatureModel
        let sessionID: DebugSessionID
        var continuation: CheckedContinuation<String?, Never>?
        var observation: AnyCancellable?

        init(feature: GenericDebugFeatureModel, sessionID: DebugSessionID) {
            self.feature = feature
            self.sessionID = sessionID
        }

        func wait() async -> String? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    guard !Task.isCancelled else { cancel(); return }
                    let observation = feature.$sessionSummaries.sink { [weak self] summaries in
                        self?.receive(summaries)
                    }
                    // Published delivers its current value inline; that can finish
                    // an attempt before the subscription has been assigned.
                    if self.continuation != nil { self.observation = observation }
                    else { observation.cancel() }
                }
            } onCancel: {
                Task { @MainActor in self.cancel() }
            }
        }

        private func receive(_ summaries: [DebugSessionSummary]) {
            guard let summary = summaries.first(where: { $0.id == sessionID }) else {
                finish(L10n.string("The debug adapter connection could not be started."))
                return
            }
            switch summary.state {
            case .idle, .terminated, .failed:
                let diagnostic = feature.activeSessionID == sessionID
                    ? (feature.errorMessage ?? String(feature.output.suffix(4_096))
                        .trimmingCharacters(in: .whitespacesAndNewlines)) : ""
                finish(diagnostic.isEmpty
                    ? L10n.string("The debug adapter connection could not be started.") : diagnostic)
            case .initializing:
                break
            case .ready, .launching, .running, .paused:
                finish(nil)
            }
        }

        private func cancel() {
            guard continuation != nil else { return }
            finish(nil)
            if feature.sessionSummaries.contains(where: { $0.id == sessionID }) {
                feature.stopSession(sessionID)
            }
        }

        private func finish(_ failure: String?) {
            let pending = continuation
            continuation = nil
            observation?.cancel()
            observation = nil
            pending?.resume(returning: failure)
        }
    }
}
