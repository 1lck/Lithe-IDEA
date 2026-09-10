import Foundation
import LitheApplicationKernel
import LitheDebugModule
import LitheExecutionModule
import LitheModuleAPI
@testable import Lithe

/// Records the application callbacks a workflow coordinator makes, so a
/// coordinator can be exercised without constructing the application shell.
///
/// `events` is append-ordered because several coordinator tests assert on the
/// order of presentation versus teardown, not just that a call happened.
@MainActor
final class WorkflowActionsSpy: DebugSessionCleanupActions, RunWorkflowActions {
    private(set) var events: [String] = []
    private(set) var savedDocuments: [EditorDocument] = []
    private(set) var recordedPreviousTexts: [String] = []
    private(set) var stoppedTerminalSessionIDs: [DebugSessionID?] = []
    private(set) var loadedProjects: [URL] = []

    /// Set to make `save` throw, covering the abort-on-failed-save path.
    var saveError: (any Error)?

    func save(_ document: EditorDocument) throws {
        if let saveError {
            events.append("save-failed")
            throw saveError
        }
        events.append("save")
        savedDocuments.append(document)
    }

    func recordSave(_ document: EditorDocument, previousText: String) {
        events.append("record-save")
        recordedPreviousTexts.append(previousText)
    }

    func showDebugToolWindow() {
        events.append("show-debug")
    }

    func activateApplication() {
        events.append("activate")
    }

    func stopJavaTestResultServer() {
        events.append("stop-java-result-server")
    }

    func stopDebugTerminalProcesses(for debugSessionID: DebugSessionID?) {
        events.append(debugSessionID == nil ? "stop-terminals" : "stop-session-terminals")
        stoppedTerminalSessionIDs.append(debugSessionID)
    }

    func loadProject(at workspaceURL: URL, files: [URL], snapshotID: UUID?) async {
        events.append("load-project")
        loadedProjects.append(workspaceURL)
    }

    func runSelectedConfiguration() {
        events.append("run")
    }

    func startDebugging() {
        events.append("debug")
    }

    func startRunConfiguration(_ configuration: RunConfiguration) {
        events.append("start:\(configuration.id)")
    }

    func runAllServiceConfigurations() {
        events.append("run-all-services")
    }

    func restartSelectedRun() {
        events.append("restart")
    }
}

/// Collects the messages a coordinator reports to the user.
@MainActor
final class NotificationSpy {
    private(set) var messages: [String] = []

    func notify(_ message: String) {
        messages.append(message)
    }
}

/// Builds a run coordinator with an empty plugin catalog and a bare module
/// runtime, for the pure-decision tests that never activate a language
/// extension.
@MainActor
func makeRunWorkflowCoordinator(
    notify: @escaping @MainActor (String) -> Void = { _ in },
    onPendingActionChange: @escaping @MainActor () -> Void = {}
) -> RunWorkflowCoordinator {
    RunWorkflowCoordinator(
        pluginCatalog: try! ValidatedPluginCatalog(
            manifests: [],
            hostVersion: BuiltInPluginCatalog.hostVersion
        ),
        moduleRuntime: ModuleRuntime(),
        notify: notify,
        onPendingActionChange: onPendingActionChange
    )
}
