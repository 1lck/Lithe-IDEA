import Foundation
import LitheDebugModule
import LitheExecutionModule

/// The application-level operations a workflow coordinator needs to call back
/// into.
///
/// Coordinators depend on these protocols rather than on closures wired at each
/// call site, so a coordinator can be driven from a test without reconstructing
/// the application shell, and the shell does not have to re-declare the same
/// callback set for every entry point. Conformances live on the application
/// aggregate; the protocols themselves must stay free of it.

/// Saving and local-history recording for an open editor document.
///
/// Run, Debug, and Java test launches all persist a dirty document before
/// starting, and each records the previous text so the save is undoable from
/// Local History.
@MainActor
protocol EditorDocumentSaving: AnyObject {
    func save(_ document: EditorDocument) throws
    func recordSave(_ document: EditorDocument, previousText: String)
}

/// Re-entry points for a run action that was deferred until the workspace
/// snapshot arrived.
///
/// `loadProject` is the workspace-wide load that brings the run inventory up to
/// a scan; the remaining members are the user-facing entry points a deferred
/// action resumes into.
@MainActor
protocol RunWorkflowActions: EditorDocumentSaving {
    func loadProject(at workspaceURL: URL, files: [URL], snapshotID: UUID?) async
    func runSelectedConfiguration()
    func startDebugging()
    func startRunConfiguration(_ configuration: RunConfiguration)
    func runAllServiceConfigurations()
    func restartSelectedRun()
}

/// Application operations the debug and Java test launch workflows call back
/// into.
///
/// A failed launch reopens the Debug tool window so the adapter's own output
/// explains the failure, which is presentation the coordinator must request
/// rather than perform.
@MainActor
protocol DebugWorkflowActions: EditorDocumentSaving {
    func showDebugToolWindow()
}

/// Presentation and teardown a debug adapter state change drives.
///
/// Terminal processes are stopped per debug session where one is known, because
/// a launch may have opened an integrated terminal that must not outlive its
/// session while other sessions' terminals stay open.
@MainActor
protocol DebugSessionCleanupActions: DebugWorkflowActions {
    func activateApplication()
    func stopJavaTestResultServer()
    func stopDebugTerminalProcesses(for debugSessionID: DebugSessionID?)
}
