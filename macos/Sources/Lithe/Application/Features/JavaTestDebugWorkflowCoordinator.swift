import Foundation

/// Coordinates the asynchronous Java test debug launch without owning the
/// generic debugger session itself.
///
/// The launch is identified by an operation ID so a second Debug Test — or a
/// cancellation — cannot let an earlier launch adopt the result server or start
/// a session that is no longer wanted.
@MainActor
final class JavaTestDebugWorkflowCoordinator {
    private let notify: @MainActor (String) -> Void
    private weak var actions: (any DebugWorkflowActions)?

    init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }

    /// Held weakly: the application aggregate owns this coordinator.
    func connect(actions: any DebugWorkflowActions) {
        self.actions = actions
    }

    func start(
        request: JavaTestDebugRequest,
        state: JavaTestWorkflowState,
        prepareDirtyDocument: @escaping () -> Bool,
        prepareLaunch: @escaping () async throws -> PreparedJavaTestDebugLaunch,
        startDebug: @escaping (PreparedJavaTestDebugLaunch) -> Bool,
        errorMessage: @escaping () -> String?
    ) {
        let operationID = state.beginDebugLaunch()
        state.debugLaunchTask = Task { @MainActor [weak self, weak state] in
            guard let self, let state else { return }
            defer { state.finishDebugLaunch(operationID, stopResultServer: false) }
            guard state.isCurrentDebugLaunch(operationID) else { return }
            guard prepareDirtyDocument() else { return }

            do {
                let prepared = try await prepareLaunch()
                guard state.isCurrentDebugLaunch(operationID) else {
                    prepared.stop()
                    return
                }
                state.stopResultServer()
                state.resultServer = prepared.resultServer
                guard startDebug(prepared) else {
                    state.stopResultServer()
                    self.notify(errorMessage() ?? "Could not debug the Java test")
                    return
                }
                self.actions?.showDebugToolWindow()
            } catch is CancellationError {
                state.finishDebugLaunch(operationID, stopResultServer: true)
            } catch {
                guard state.isCurrentDebugLaunch(operationID) else { return }
                state.finishDebugLaunch(operationID, stopResultServer: true)
                self.notify(error.localizedDescription)
            }
        }
    }
}
