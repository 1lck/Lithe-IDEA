import Foundation
import LitheCoreContracts
import LitheDebugModule

/// Coordinates presentation and resource cleanup as a debug adapter session
/// changes state.
///
/// A Java launch may request an integrated terminal before the adapter reaches
/// `running`, so terminal teardown is keyed on the session that owned it rather
/// than stopping every debug terminal.
@MainActor
final class DebugSessionCleanupCoordinator {
    private weak var actions: (any DebugSessionCleanupActions)?

    /// Held weakly: the application aggregate owns this coordinator.
    func connect(actions: any DebugSessionCleanupActions) {
        self.actions = actions
    }

    func handle(
        _ state: DebugAdapterState,
        activeSessionID: DebugSessionID?
    ) {
        guard let actions else { return }
        switch state {
        case .launching, .running:
            actions.showDebugToolWindow()
        case .paused:
            actions.showDebugToolWindow()
            actions.activateApplication()
        case .terminated, .failed:
            actions.stopJavaTestResultServer()
            actions.stopDebugTerminalProcesses(for: activeSessionID)
        default:
            break
        }
    }
}
