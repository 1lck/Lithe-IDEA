import Foundation
import Testing
@testable import Lithe

@Suite("Language navigation coordinator")
struct LanguageNavigationCoordinatorTests {
    @Test("projects language-server locations")
    @MainActor
    func projectsLocations() {
        let coordinator = LanguageNavigationCoordinator(notify: { _ in })
        let url = URL(fileURLWithPath: "/workspace/Source.java")
        let values = [
            LanguageServerLocation(
                url: url,
                range: LanguageServerRange(
                    start: LanguageServerPosition(line: 4, utf16Column: 7),
                    end: LanguageServerPosition(line: 4, utf16Column: 12)
                ),
                isReadOnly: false,
                displayPath: "Source.java"
            )
        ]

        let locations = coordinator.locations(from: values)

        #expect(locations.count == 1)
        #expect(locations[0].url == url)
        #expect(locations[0].line == 4)
        #expect(locations[0].utf16Column == 7)
        #expect(locations[0].displayPath == "Source.java")
    }

    @Test("does not create a result state for an empty response")
    @MainActor
    func emptyResponseIsIgnored() {
        let coordinator = LanguageNavigationCoordinator(notify: { _ in })

        #expect(
            coordinator.resultState(
                from: [],
                providerID: "java",
                kind: .definitions
            ) == nil
        )
    }

    @Test("publishes a loading state that owns the returned operation ID")
    @MainActor
    func loadingStateOwnsOperationID() {
        let coordinator = LanguageNavigationCoordinator(notify: { _ in })
        let operationID = coordinator.begin(providerID: "java", kind: .references)

        #expect(coordinator.owns(operationID))
        #expect(coordinator.state.providerID == "java")
        #expect(coordinator.state.kind == .references)
    }

    /// A superseded request must not clear the state a newer one published,
    /// which is what keeps a slow response from blanking fresh results.
    @Test("ignores a failure reported by a superseded request")
    @MainActor
    func ignoresSupersededFailure() {
        var messages: [String] = []
        let coordinator = LanguageNavigationCoordinator(notify: { messages.append($0) })
        let stale = coordinator.begin(providerID: "java", kind: .definitions)
        let current = coordinator.begin(providerID: "java", kind: .references)

        coordinator.fail(stale, message: "stale failure")

        #expect(coordinator.owns(current))
        #expect(coordinator.state.isLoading)
        // The message still reaches the user; only the state write is skipped.
        #expect(messages == ["stale failure"])
    }

    @Test("clears the state when the current request fails")
    @MainActor
    func clearsStateOnCurrentFailure() {
        var messages: [String] = []
        let coordinator = LanguageNavigationCoordinator(notify: { messages.append($0) })
        let operationID = coordinator.begin(providerID: "java", kind: .definitions)

        coordinator.fail(operationID, message: "definition failed")

        #expect(!coordinator.state.isLoading)
        #expect(messages == ["definition failed"])
    }

    @Test("reports an empty response without publishing results")
    @MainActor
    func reportsEmptyResponse() {
        let coordinator = LanguageNavigationCoordinator(notify: { _ in })
        coordinator.begin(providerID: "java", kind: .definitions)
        var events: [String] = []

        coordinator.handleResult(
            [],
            providerID: "java",
            kind: .definitions,
            onEmpty: { events.append("empty") },
            onResults: { _ in Issue.record("no results were returned") }
        )

        #expect(events == ["empty"])
        #expect(!coordinator.state.isLoading)
    }

    @Test("routes file navigation through explicit editor callbacks")
    @MainActor
    func routesFileNavigation() {
        let coordinator = LanguageNavigationCoordinator(
            notify: { _ in Issue.record("file navigation must not notify") }
        )
        let url = URL(fileURLWithPath: "/workspace/Target.swift")
        let location = EditorNavigationLocation(
            url: url,
            line: 8,
            utf16Column: 3,
            isReadOnly: true,
            displayPath: "Target.swift"
        )
        var events: [String] = []

        coordinator.navigate(
            to: location,
            recordsHistory: true,
            providerID: nil,
            sessions: nil,
            recordHistory: { destination in
                events.append("history:\(destination.line)")
            },
            openFile: { destination in
                events.append("open:\(destination.url.lastPathComponent)")
            },
            openVirtualDocument: { _, _, _ in
                Issue.record("file navigation must not open a virtual document")
            },
            setTarget: { destination in
                events.append("target:\(destination.utf16Column)")
            }
        )

        #expect(events == ["history:8", "open:Target.swift", "target:3"])
        // A local file needs no provider round trip, so no operation starts.
        #expect(!coordinator.state.isLoading)
    }

    @Test("requests implementation fallback only for a self definition")
    @MainActor
    func decidesImplementationFallback() {
        let coordinator = LanguageNavigationCoordinator(notify: { _ in })
        let url = URL(fileURLWithPath: "/workspace/Main.java")
        let location = LanguageServerLocation(
            url: url,
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 0, utf16Column: 0),
                end: LanguageServerPosition(line: 0, utf16Column: 1)
            ),
            isReadOnly: false,
            displayPath: nil
        )

        let decision = coordinator.implementationFallbackDecision(
            method: "textDocument/definition",
            kind: .definitions,
            values: [location],
            documentURL: url,
            supportsImplementation: true
        )

        #expect(decision.shouldRequestImplementations)
        #expect(decision.originalValues.count == 1)
    }
}

@Suite("Java test workflow state")
struct JavaTestWorkflowStateTests {
    @Test("resolves a Java test case request")
    @MainActor
    func resolvesTestCase() {
        let state = JavaTestWorkflowState(notify: { _ in })
        let url = URL(fileURLWithPath: "/workspace/Test.java")

        let result = state.resolveDebugRequest(
            providerID: "java",
            scope: .testCase(identifier: "Example.test", fileURL: url)
        )

        guard case .resolved(let request) = result else {
            Issue.record("expected a resolved Java test request")
            return
        }
        #expect(request.fileURL == url.standardizedFileURL)
        #expect(request.testIdentifier == "Example.test")
    }

    @Test("rejects a workspace-wide Java debug request")
    @MainActor
    func rejectsWorkspaceRequest() {
        let state = JavaTestWorkflowState(notify: { _ in })

        guard case .rejected(let message) = state.resolveDebugRequest(
            providerID: "java",
            scope: .workspace
        ) else {
            Issue.record("expected workspace debugging to be rejected")
            return
        }
        #expect(message == "Select a Java test file or test case to debug")
    }

    @Test("does not require a save for an absent document")
    @MainActor
    func absentDocumentIsReady() {
        let notifications = NotificationSpy()
        let state = JavaTestWorkflowState(notify: notifications.notify)
        let actions = WorkflowActionsSpy()

        let ready = state.prepareDirtyDocument(
            fileURL: URL(fileURLWithPath: "/workspace/Test.java"),
            documents: [],
            saving: actions
        )

        #expect(ready)
        #expect(actions.events.isEmpty)
        #expect(notifications.messages.isEmpty)
    }
}

@Suite("Language editing coordinator")
struct LanguageEditingCoordinatorTests {
    @Test("normalizes language-server positions")
    @MainActor
    func normalizesPosition() {
        let position = LanguageEditingCoordinator(notify: { _ in }).position(line: -2, utf16Column: -1)
        #expect(position.line == 0)
        #expect(position.utf16Column == 0)
    }

    @Test("deduplicates completion labels while preserving order")
    @MainActor
    func deduplicatesCompletions() {
        let coordinator = LanguageEditingCoordinator(notify: { _ in })
        let local = [
            LanguageServerCompletionItem(label: "local", detail: nil, documentation: nil, insertText: "local", sortText: nil, filterText: nil, kind: nil, textEdit: nil, additionalTextEdits: [], data: nil),
            LanguageServerCompletionItem(label: "shared", detail: nil, documentation: nil, insertText: "shared", sortText: nil, filterText: nil, kind: nil, textEdit: nil, additionalTextEdits: [], data: nil)
        ]
        let remote = [
            LanguageServerCompletionItem(label: "shared", detail: nil, documentation: nil, insertText: "shared", sortText: nil, filterText: nil, kind: nil, textEdit: nil, additionalTextEdits: [], data: nil),
            LanguageServerCompletionItem(label: "remote", detail: nil, documentation: nil, insertText: "remote", sortText: nil, filterText: nil, kind: nil, textEdit: nil, additionalTextEdits: [], data: nil)
        ]

        let merged = coordinator.mergeCompletions(local, with: remote)

        #expect(merged.map(\.label) == ["local", "shared", "remote"])
    }

    @Test("builds completion edits with a plain-text primary edit")
    @MainActor
    func buildsCompletionWorkspaceEdit() {
        let coordinator = LanguageEditingCoordinator(notify: { _ in })
        let url = URL(fileURLWithPath: "/workspace/Main.java")
        let fallbackRange = LanguageServerRange(
            start: LanguageServerPosition(line: 2, utf16Column: 1),
            end: LanguageServerPosition(line: 2, utf16Column: 4)
        )
        let item = LanguageServerCompletionItem(
            label: "println",
            detail: nil,
            documentation: nil,
            insertText: "${1:println}",
            sortText: nil,
            filterText: nil,
            kind: nil,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )

        let edit = coordinator.completionWorkspaceEdit(
            item,
            fallbackRange: fallbackRange,
            documentURL: url
        )

        #expect(edit.changes.count == 1)
        #expect(edit.changes.keys.contains(url))
        #expect(edit.changes[url]?.count == 1)
        #expect(edit.changes[url]?.first?.newText == "println")
        #expect(edit.changes[url]?.first?.range == fallbackRange)
    }

    @Test("builds a zero-width code action range from the editor position")
    @MainActor
    func buildsCodeActionRange() {
        let request = LanguageEditingCoordinator(notify: { _ in }).codeActionRequest(
            line: -1,
            utf16Column: 5
        )

        #expect(request.position.line == 0)
        #expect(request.position.utf16Column == 5)
        #expect(request.range.start == request.position)
        #expect(request.range.end == request.position)
    }

    @Test("applies a code action edit before executing its command")
    @MainActor
    func appliesCodeActionEditBeforeCommand() {
        let coordinator = LanguageEditingCoordinator(
            notify: { _ in Issue.record("unexpected notification") }
        )
        let edit = LanguageServerWorkspaceEdit(changes: [:])
        let action = LanguageServerCodeAction(
            title: "Fix",
            kind: nil,
            isPreferred: false,
            edit: edit,
            command: LanguageServerCommand(
                title: "Run",
                command: "fix.run",
                arguments: []
            ),
            data: nil
        )
        var events: [String] = []

        coordinator.applyCodeAction(
            action,
            applyEdit: { _ in
                events.append("edit")
                return true
            },
            executeCommand: { _ in events.append("command") }
        )

        #expect(events == ["edit", "command"])
    }

    @Test("does not execute a command after a failed code action edit")
    @MainActor
    func stopsAfterFailedCodeActionEdit() {
        let coordinator = LanguageEditingCoordinator(
            notify: { _ in Issue.record("unexpected notification") }
        )
        let action = LanguageServerCodeAction(
            title: "Fix",
            kind: nil,
            isPreferred: false,
            edit: LanguageServerWorkspaceEdit(changes: [:]),
            command: LanguageServerCommand(title: "Run", command: "fix.run", arguments: []),
            data: nil
        )
        var executed = false

        coordinator.applyCodeAction(
            action,
            applyEdit: { _ in false },
            executeCommand: { _ in executed = true }
        )

        #expect(!executed)
    }

    @Test("notifies when a code action has no executable change")
    @MainActor
    func notifiesForCodeActionWithoutChange() {
        var message: String?
        let coordinator = LanguageEditingCoordinator(notify: { message = $0 })
        let action = LanguageServerCodeAction(
            title: "Info",
            kind: nil,
            isPreferred: false,
            edit: nil,
            command: nil,
            data: nil
        )

        coordinator.applyCodeAction(
            action,
            applyEdit: { _ in Issue.record("unexpected edit"); return true },
            executeCommand: { _ in Issue.record("unexpected command") }
        )

        #expect(message == "This language action has no executable change.")
    }

    @Test("routes successful rename edits and failed requests")
    @MainActor
    func handlesWorkspaceEditResult() {
        var message: String?
        let coordinator = LanguageEditingCoordinator(notify: { message = $0 })
        let edit = LanguageServerWorkspaceEdit(changes: [:])
        var applied = false

        coordinator.handleWorkspaceEditResult(
            .success(edit),
            apply: { _ in applied = true }
        )
        #expect(applied)
        #expect(message == nil)

        coordinator.handleWorkspaceEditResult(
            .failure(TestEditingError.failed),
            apply: { _ in Issue.record("unexpected apply") }
        )
        #expect(message == "editing failed")
    }

    @Test("wraps formatting edits in a workspace edit")
    @MainActor
    func handlesFormattingResult() {
        let coordinator = LanguageEditingCoordinator(
            notify: { _ in Issue.record("unexpected notification") }
        )
        let url = URL(fileURLWithPath: "/workspace/Main.java")
        let edit = LanguageServerTextEdit(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 0, utf16Column: 0),
                end: LanguageServerPosition(line: 0, utf16Column: 1)
            ),
            newText: "x"
        )
        var appliedEdit: LanguageServerWorkspaceEdit?

        coordinator.handleFormattingResult(
            .success([edit]),
            documentURL: url,
            apply: { appliedEdit = $0 }
        )

        #expect(appliedEdit?.changes[url]?.first?.newText == "x")
    }

    @Test("returns completion fallback after a failed language-server request")
    @MainActor
    func handlesCompletionFailure() {
        var message: String?
        let coordinator = LanguageEditingCoordinator(notify: { message = $0 })
        let fallback = [
            LanguageServerCompletionItem(
                label: "local",
                detail: nil,
                documentation: nil,
                insertText: "local",
                sortText: nil,
                filterText: nil,
                kind: nil,
                textEdit: nil,
                additionalTextEdits: [],
                data: nil
            )
        ]
        var result: [LanguageServerCompletionItem] = []

        coordinator.handleCompletionResult(
            .failure(TestEditingError.failed),
            fallback: fallback,
            completion: { result = $0 }
        )

        #expect(result.map(\.label) == ["local"])
        #expect(message == "editing failed")
    }

    @Test("returns hover values and reports hover failures")
    @MainActor
    func handlesHoverFailure() {
        var message: String?
        let coordinator = LanguageEditingCoordinator(notify: { message = $0 })
        var hover: LanguageServerHover?

        coordinator.handleHoverResult(
            .failure(TestEditingError.failed),
            completion: { hover = $0 }
        )

        #expect(hover == nil)
        #expect(message == "editing failed")
    }

    @Test("falls back when completion resolve fails")
    @MainActor
    func handlesResolvedCompletionFailure() {
        var message: String?
        let coordinator = LanguageEditingCoordinator(notify: { message = $0 })
        var didFallback = false

        coordinator.handleResolvedCompletionResult(
            .failure(TestEditingError.failed),
            fallback: { didFallback = true },
            apply: { _ in Issue.record("unexpected apply") }
        )

        #expect(didFallback)
        #expect(message == "editing failed")
    }

    @Test("applies a resolved code action")
    @MainActor
    func handlesResolvedCodeAction() {
        let coordinator = LanguageEditingCoordinator(
            notify: { _ in Issue.record("unexpected notification") }
        )
        let action = LanguageServerCodeAction(
            title: "Fix",
            kind: nil,
            isPreferred: true,
            edit: nil,
            command: nil,
            data: nil
        )
        var applied = false

        coordinator.handleResolvedCodeActionResult(
            .success(action),
            apply: { _ in applied = true }
        )

        #expect(applied)
    }
}

private enum TestEditingError: LocalizedError {
    case failed

    var errorDescription: String? { "editing failed" }
}
