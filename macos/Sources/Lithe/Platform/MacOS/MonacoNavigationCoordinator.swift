import Combine
import Foundation

/// Decides when an editor navigation target becomes a Monaco jump.
///
/// SwiftUI calls the workbench's `update()` only when a view input changes.
/// A jump inside the document that is already open changes no input, so the
/// coordinator also re-presents the editor whenever the target itself
/// changes. Each target is applied once, to the document it names.
@MainActor
final class MonacoNavigationCoordinator {
    private var appliedID: UUID?
    private var subscription: AnyCancellable?

    /// Starts following `targets`; later calls are ignored. `present` runs
    /// only once the editor is ready — until then the editor's own ready
    /// handshake presents the pending target.
    func observe(
        _ targets: AnyPublisher<EditorNavigationTarget?, Never>,
        isReady: @escaping @MainActor () -> Bool,
        present: @escaping @MainActor () -> Void
    ) {
        guard subscription == nil else { return }
        subscription = targets.sink { _ in
            MainActor.assumeIsolated {
                if isReady() { present() }
            }
        }
    }

    /// The target to jump to in `documentURL`, or nil when the target names
    /// another document or was already applied.
    func jump(for target: EditorNavigationTarget?, in documentURL: URL) -> EditorNavigationTarget? {
        guard let target, appliedID != target.id,
              target.url.standardizedFileURL == documentURL.standardizedFileURL else { return nil }
        appliedID = target.id
        return target
    }
}
