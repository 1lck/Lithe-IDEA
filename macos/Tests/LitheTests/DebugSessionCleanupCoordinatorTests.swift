import Testing
import LitheDebugModule
@testable import Lithe

@Suite("Debug session cleanup coordinator")
struct DebugSessionCleanupCoordinatorTests {
    @Test("cleans Java and terminal resources after termination")
    @MainActor
    func cleansResourcesAfterTermination() {
        let coordinator = DebugSessionCleanupCoordinator()
        let actions = WorkflowActionsSpy()
        coordinator.connect(actions: actions)
        let sessionID = DebugSessionID()

        coordinator.handle(.terminated, activeSessionID: sessionID)

        #expect(actions.events == ["stop-java-result-server", "stop-session-terminals"])
        #expect(actions.stoppedTerminalSessionIDs == [sessionID])
    }

    /// Without an active session the debugger never reported one, so every
    /// debug terminal is stopped rather than leaking a process.
    @Test("stops all debug terminals when no session is active")
    @MainActor
    func stopsAllTerminalsWithoutSession() {
        let coordinator = DebugSessionCleanupCoordinator()
        let actions = WorkflowActionsSpy()
        coordinator.connect(actions: actions)

        coordinator.handle(.failed, activeSessionID: nil)

        #expect(actions.events == ["stop-java-result-server", "stop-terminals"])
        #expect(actions.stoppedTerminalSessionIDs == [nil])
    }

    @Test("activates the application when the debugger pauses")
    @MainActor
    func activatesOnPause() {
        let coordinator = DebugSessionCleanupCoordinator()
        let actions = WorkflowActionsSpy()
        coordinator.connect(actions: actions)

        coordinator.handle(.paused, activeSessionID: nil)

        #expect(actions.events == ["show-debug", "activate"])
    }
}
