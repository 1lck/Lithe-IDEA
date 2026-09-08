import Foundation
import Testing
import LitheCoreContracts
import LitheModuleAPI
@testable import Lithe

@Suite("Run workflow coordinator")
@MainActor
struct RunWorkflowCoordinatorTests {
    @Test("selects file language support for current-file configurations")
    func selectsFileSupportForCurrentFile() {
        let coordinator = makeRunWorkflowCoordinator()
        let fileURL = URL(fileURLWithPath: "/workspace/Main.go")
        let fileSupport = makeSupport(id: "go")
        let providerSupport = makeSupport(id: "java")
        let configuration = RunConfiguration(
            id: RunConfiguration.currentFileID,
            name: "Current File",
            kind: .currentFile,
            modulePath: nil,
            mainClass: nil
        )

        let selected = coordinator.languageSupport(
            for: configuration,
            currentFileURL: fileURL,
            languageSupportForFile: { _ in fileSupport },
            languageSupportForProvider: { _ in providerSupport }
        )

        #expect(selected?.id == "go")
    }

    @Test("selects provider language support for named configurations")
    func selectsProviderSupportForNamedConfiguration() {
        let coordinator = makeRunWorkflowCoordinator()
        let providerSupport = makeSupport(id: "java")
        let configuration = RunConfiguration(
            id: "java-main",
            name: "Main",
            kind: .javaMain,
            modulePath: nil,
            mainClass: "Main"
        )

        let selected = coordinator.languageSupport(
            for: configuration,
            currentFileURL: nil,
            languageSupportForFile: { _ in
                Issue.record("file support should not be queried")
                return nil
            },
            languageSupportForProvider: { providerID in
                #expect(providerID == configuration.kind.providerID)
                return providerSupport
            }
        )

        #expect(selected?.id == "java")
    }

    @Test("dispatches each deferred run action to its matching entry point")
    func dispatchesDeferredActions() {
        let coordinator = makeRunWorkflowCoordinator()
        let actions = WorkflowActionsSpy()
        coordinator.connect(actions: actions)
        let configuration = RunConfiguration(
            id: "java-main",
            name: "Main",
            kind: .javaMain,
            modulePath: nil,
            mainClass: "Main"
        )

        coordinator.performDeferredAction(.startConfiguration(configuration))
        coordinator.performDeferredAction(.restart)

        #expect(actions.events == ["start:java-main", "restart"])
    }

    /// The pending action belongs to the opening that recorded it. A resume for
    /// a different opening must leave it queued rather than firing it against
    /// the wrong workspace.
    @Test("keeps a deferred action queued when a different opening resumes")
    func keepsDeferredActionForOtherOpening() {
        let coordinator = makeRunWorkflowCoordinator()
        let actions = WorkflowActionsSpy()
        coordinator.connect(actions: actions)
        let identity = WorkspaceIdentity(
            url: URL(fileURLWithPath: "/workspace-a"),
            generation: 1
        )
        let otherIdentity = WorkspaceIdentity(
            url: URL(fileURLWithPath: "/workspace-b"),
            generation: 1
        )

        coordinator.deferAction(.run, for: identity)
        coordinator.clearPendingAction(for: otherIdentity)

        #expect(coordinator.pendingAction?.kind == .run)
        #expect(coordinator.pendingAction?.identity == identity)
        #expect(actions.events.isEmpty)
    }

    @Test("clears a deferred action for its own opening")
    func clearsDeferredActionForSameOpening() {
        let coordinator = makeRunWorkflowCoordinator()
        let identity = WorkspaceIdentity(
            url: URL(fileURLWithPath: "/workspace-a"),
            generation: 1
        )

        coordinator.deferAction(.debug, for: identity)
        coordinator.clearPendingAction(for: identity)

        #expect(coordinator.pendingAction == nil)
    }

    /// Defer and resume are invisible to `objectWillChange` observers unless the
    /// coordinator reports the change, because the pending action is not
    /// published state.
    @Test("reports pending action changes exactly once per transition")
    func reportsPendingActionChanges() {
        var changes = 0
        let coordinator = makeRunWorkflowCoordinator(
            onPendingActionChange: { changes += 1 }
        )
        let identity = WorkspaceIdentity(
            url: URL(fileURLWithPath: "/workspace-a"),
            generation: 1
        )

        coordinator.deferAction(.run, for: identity)
        coordinator.deferAction(.run, for: identity)
        coordinator.resetPendingAction()
        coordinator.resetPendingAction()

        #expect(changes == 2)
    }

    @Test("saves a dirty current-file document before running")
    func savesDirtyCurrentFile() {
        let notifications = NotificationSpy()
        let coordinator = makeRunWorkflowCoordinator(notify: notifications.notify)
        let actions = WorkflowActionsSpy()
        let configuration = RunConfiguration(
            id: RunConfiguration.currentFileID,
            name: "Current File",
            kind: .currentFile,
            modulePath: nil,
            mainClass: nil
        )
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/workspace/Main.go"),
            text: "changed",
            modificationDate: nil
        )
        document.text = "changed again"

        let ready = coordinator.saveDirtyCurrentFileIfNeeded(
            configuration: configuration,
            document: document,
            saving: actions
        )

        #expect(ready)
        #expect(actions.events == ["save", "record-save"])
        #expect(actions.recordedPreviousTexts == ["changed"])
        #expect(notifications.messages.isEmpty)
    }

    /// Running a stale file would compile text the user never saved, so a failed
    /// save blocks the launch and says why.
    @Test("blocks the run when the current file cannot be saved")
    func blocksRunOnFailedSave() {
        let notifications = NotificationSpy()
        let coordinator = makeRunWorkflowCoordinator(notify: notifications.notify)
        let actions = WorkflowActionsSpy()
        actions.saveError = CocoaError(.fileWriteNoPermission)
        let configuration = RunConfiguration(
            id: RunConfiguration.currentFileID,
            name: "Current File",
            kind: .currentFile,
            modulePath: nil,
            mainClass: nil
        )
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/workspace/Main.go"),
            text: "changed",
            modificationDate: nil
        )
        document.text = "changed again"

        let ready = coordinator.saveDirtyCurrentFileIfNeeded(
            configuration: configuration,
            document: document,
            saving: actions
        )

        #expect(!ready)
        #expect(notifications.messages == ["Could not save Main.go"])
    }

    @Test("does not save a clean non-current-file configuration")
    func skipsUnneededSave() {
        let notifications = NotificationSpy()
        let coordinator = makeRunWorkflowCoordinator(notify: notifications.notify)
        let actions = WorkflowActionsSpy()
        let configuration = RunConfiguration(
            id: "java-main",
            name: "Main",
            kind: .javaMain,
            modulePath: nil,
            mainClass: "Main"
        )

        let ready = coordinator.saveDirtyCurrentFileIfNeeded(
            configuration: configuration,
            document: nil,
            saving: actions
        )

        #expect(ready)
        #expect(actions.events.isEmpty)
        #expect(notifications.messages.isEmpty)
    }

    @Test("classifies a ready selected configuration")
    func classifiesReadyConfiguration() {
        let configuration = RunConfiguration(
            id: "java-main",
            name: "Main",
            kind: .javaMain,
            modulePath: nil,
            mainClass: "Main"
        )

        guard case .ready(let selected) = makeRunWorkflowCoordinator().configurationReadiness(
            status: .ready,
            selected: configuration
        ) else {
            Issue.record("expected a ready configuration")
            return
        }
        #expect(selected == configuration)
    }

    @Test("requests generation when the configuration status is not ready")
    func classifiesConfigurationGeneration() {
        let result = makeRunWorkflowCoordinator().configurationReadiness(
            status: .missing,
            selected: nil
        )

        guard case .needsGeneration = result else {
            Issue.record("expected configuration generation")
            return
        }
    }

    @Test("reports a missing current-file debug source")
    func reportsMissingCurrentFileSource() {
        let configuration = RunConfiguration(
            id: RunConfiguration.currentFileID,
            name: "Current File",
            kind: .currentFile,
            modulePath: nil,
            mainClass: nil
        )

        let result = makeRunWorkflowCoordinator().resolveDebugSource(
            configuration: configuration,
            activeDocument: nil,
            projectFiles: [],
            workspaceURL: URL(fileURLWithPath: "/workspace")
        )

        guard case .currentFileUnavailable = result else {
            Issue.record("expected missing current-file source")
            return
        }
    }

    @Test("reports unsupported debug providers by source file name")
    func reportsUnsupportedDebugProvider() {
        let sourceURL = URL(fileURLWithPath: "/workspace/Main.rb")
        let result = makeRunWorkflowCoordinator().debugProviderReadiness(
            sourceURL: sourceURL,
            supportsDebugAdapter: false
        )

        guard case .unsupported(let fileName) = result else {
            Issue.record("expected unsupported provider")
            return
        }
        #expect(fileName == "Main.rb")
    }

    private func makeSupport(id: String) -> LanguageSupportDeclaration {
        LanguageSupportDeclaration(
            id: id,
            displayName: id,
            fileExtensions: [id],
            projectFileNames: [],
            languageServerModuleID: .languageServerExtension(id),
            executionModuleID: .languageExecutionExtension(id),
            testingModuleID: nil
        )
    }
}
