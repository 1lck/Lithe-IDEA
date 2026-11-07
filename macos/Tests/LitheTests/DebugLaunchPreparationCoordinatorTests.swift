import Foundation
import Testing
@testable import Lithe

@Suite("Debug launch preparation coordinator")
@MainActor
struct DebugLaunchPreparationCoordinatorTests {
    @Test("saves a dirty debug document and records its previous text")
    func savesDirtyDocument() async {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/workspace/example.txt"),
            text: "before",
            modificationDate: nil
        )
        document.text = "after"
        let notifications = NotificationSpy()
        let actions = WorkflowActionsSpy()
        let coordinator = DebugLaunchPreparationCoordinator(notify: notifications.notify)
        coordinator.connect(actions: actions)

        let ready = await coordinator.saveDirtyDocumentIfNeeded(document)

        #expect(ready)
        #expect(actions.events == ["save", "record-save"])
        #expect(actions.recordedPreviousTexts == ["before"])
        #expect(notifications.messages.isEmpty)
    }

    @Test("skips clean debug documents")
    func skipsCleanDocument() async {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/workspace/example.txt"),
            text: "source",
            modificationDate: nil
        )
        let notifications = NotificationSpy()
        let actions = WorkflowActionsSpy()
        let coordinator = DebugLaunchPreparationCoordinator(notify: notifications.notify)
        coordinator.connect(actions: actions)

        let ready = await coordinator.saveDirtyDocumentIfNeeded(document)

        #expect(ready)
        #expect(actions.events.isEmpty)
        #expect(notifications.messages.isEmpty)
    }

    /// A launch must not proceed from a source file the build will not see;
    /// a failed save aborts instead of debugging the stale text on disk.
    @Test("aborts the launch when the dirty document cannot be saved")
    func abortsOnFailedSave() async {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/workspace/example.txt"),
            text: "before",
            modificationDate: nil
        )
        document.text = "after"
        let notifications = NotificationSpy()
        let actions = WorkflowActionsSpy()
        actions.saveError = CocoaError(.fileWriteNoPermission)
        let coordinator = DebugLaunchPreparationCoordinator(notify: notifications.notify)
        coordinator.connect(actions: actions)

        let ready = await coordinator.saveDirtyDocumentIfNeeded(document)

        #expect(!ready)
        #expect(notifications.messages == ["Could not save %@"])
        #expect(notifications.arguments == [["example.txt"]])
    }

    @Test("reports a failed debug launch and reopens the debug tool window")
    func reportsFailedLaunch() {
        let configuration = DebugLaunchConfiguration(
            name: "example",
            request: .launch,
            arguments: [:]
        )
        let notifications = NotificationSpy()
        let actions = WorkflowActionsSpy()
        let coordinator = DebugLaunchPreparationCoordinator(notify: notifications.notify)
        coordinator.connect(actions: actions)

        let started = coordinator.start(
            configuration: configuration,
            launch: { false },
            errorMessage: "launch failed"
        )

        #expect(!started)
        #expect(notifications.messages == ["launch failed"])
        #expect(actions.events == ["show-debug"])
    }

    @Test("returns success without failure handling for a successful launch")
    func acceptsSuccessfulLaunch() {
        let notifications = NotificationSpy()
        let actions = WorkflowActionsSpy()
        let coordinator = DebugLaunchPreparationCoordinator(notify: notifications.notify)
        coordinator.connect(actions: actions)

        let started = coordinator.start(
            configuration: DebugLaunchConfiguration(
                name: "example",
                request: .launch,
                arguments: [:]
            ),
            launch: { true },
            errorMessage: nil
        )

        #expect(started)
        #expect(notifications.messages.isEmpty)
        #expect(actions.events.isEmpty)
    }
}
