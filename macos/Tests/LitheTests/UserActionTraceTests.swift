import Foundation
import LitheModuleAPI
import Testing
@testable import Lithe
@testable import LitheGitModule

private func token(_ value: LogFieldValue?) -> String? {
    if case .token(let text) = value { return text }
    return nil
}

@MainActor
private final class ObservedOperation {
    var value: String?
}

@Suite("User action trace")
struct UserActionTraceTests {
    @Test
    func outermostEntryLogsOnceAndNestedEntriesKeepItsOperation() throws {
        let recorder = TypedLogRecorder()
        let (outer, inner) = UserActionTrace.run("vcs.commit", surface: .button, sink: recorder) {
            let outer = UserActionContext.current
            let inner = UserActionTrace.run("vcs.push", surface: .menu, sink: recorder) { UserActionContext.current }
            return (outer, inner)
        }
        let action = try #require(outer)
        #expect(inner?.operationID == action.operationID)
        #expect(inner?.id == "vcs.commit")
        #expect(UserActionContext.current == nil)
        #expect(recorder.events.count == 1)
        let event = try #require(recorder.events.first as? AppActionPerformed)
        #expect(event.operationID == action.operationID)
        #expect(token(event.fields["action"]) == "vcs.commit")
        #expect(token(event.fields["surface"]) == "button")
    }

    @Test
    func childTasksAndDetachedHopsKeepTheActionButPlainDetachedTasksDoNot() async throws {
        let recorder = TypedLogRecorder()
        let observed = await UserActionTrace.run("workspace.folder.open", surface: .contextMenu, sink: recorder) {
            let child = await Task { UserActionContext.current?.operationID }.value
            let detached = await UserActionContext.detached { UserActionContext.current?.operationID }.value
            let plain = await Task.detached { UserActionContext.current?.operationID }.value
            return (UserActionContext.current?.operationID, child, detached, plain)
        }
        let operation = try #require(observed.0)
        #expect(observed.1 == operation)
        #expect(observed.2 == operation)
        #expect(observed.3 == nil)
        let event = try #require(recorder.events.first as? AppActionPerformed)
        #expect(event.operationID == operation)
        #expect(token(event.fields["surface"]) == "context_menu")
    }

    @Test
    func actionIDsAreCatalogTokensNeverTitles() {
        #expect(UserActionTrace.normalizedID("plugin:dev.lithe.maven/run-goal") == "plugin:dev.lithe.maven/run-goal")
        #expect(UserActionTrace.normalizedID("vcs.git.branch.checkout") == "vcs.git.branch.checkout")
        #expect(UserActionTrace.normalizedID("Commit 提交") == "invalid")
        #expect(UserActionTrace.normalizedID("") == "invalid")
        #expect(UserActionTrace.normalizedID(String(repeating: "a", count: 65)) == "invalid")
        let recorder = TypedLogRecorder()
        UserActionTrace.run("/Users/someone/project file", surface: .palette, sink: recorder) {}
        let event = recorder.events.first as? AppActionPerformed
        #expect(token(event?.fields["action"]) == "invalid")
    }

    @Test @MainActor
    func mainQueueHopsKeepTheAction() async throws {
        let gate = TestGate()
        let observed = ObservedOperation()
        let action = try #require(UserActionTrace.run("workspace.open", surface: .button, sink: nil) { () -> UserAction? in
            UserActionContext.mainAsync {
                observed.value = UserActionContext.current?.operationID
                gate.open()
            }
            return UserActionContext.current
        })
        #expect(await gate.waitUntilOpen(timeout: .seconds(2)))
        #expect(observed.value == action.operationID)
    }

    @Test @MainActor
    func menuItemsTraceTheirKeyOrSubmenuNeverTheTitleTheyShow() {
        var seen: [String?] = []
        let record = { seen.append(UserActionContext.current?.id) }
        let menu: [LitheContextMenuItem] = [
            .action("Copy Revision Number", action: record),
            .action("Run", actionID: "run.gutter", action: record),
            .submenu("Checkout Branch", items: [.action("feature/客户", localizesTitle: false, action: record)]),
        ]
        let items = menu.map { $0.traced(surface: .contextMenu) }
        items[0].action()
        items[1].action()
        if case .submenu(let children) = items[2].kind { children[0].action() }
        #expect(seen == ["menu:copy-revision-number", "run.gutter", "menu:checkout-branch"])

        #expect(LitheContextMenuItem.traceID(forKey: "Reload %@ projects") == "menu:reload-projects")
        #expect(LitheContextMenuItem.traceID(forKey: "提交") == "menu:item")
        #expect(UserActionTrace.normalizedID(LitheContextMenuItem.traceID(forKey: String(repeating: "word ", count: 30)))
            != "invalid")
    }

    @Test
    func gitPanelOperationsLogUnderTheModelMethodThatOwnsThem() {
        #expect(GitFeatureModel.operationActionID("pushReviewed(_:to:)") == "vcs.git.pushReviewed")
        #expect(GitFeatureModel.operationActionID("fetch()") == "vcs.git.fetch")
        #expect(GitFeatureModel.operationActionID("commit") == "vcs.git.commit")
    }

    @Test
    func requestOriginMarksOnlyRecentActionsAsUserStarted() {
        let start = ContinuousClock.now
        let action = UserAction(id: "vcs.commit", surface: .button, operationID: "action-op", startedAt: start)
        typealias Origin = RustCoreBridge.RequestOrigin
        #expect(Origin.resolve(action: action, gitSource: .background, now: start) == Origin(source: "background"))
        #expect(Origin.resolve(action: action, gitSource: .unknown, now: start + .seconds(1))
            == Origin(source: "user", trigger: "vcs.commit", operation: "action-op"))
        // Long-lived work keeps the action's operation but stops claiming user provenance.
        #expect(Origin.resolve(action: action, gitSource: .unknown, now: start + .seconds(61))
            == Origin(source: nil, trigger: "vcs.commit", operation: "action-op"))
        #expect(Origin.resolve(action: nil, gitSource: .user, now: start) == Origin(source: "user"))
        #expect(Origin.resolve(action: nil, gitSource: .unknown, now: start) == nil)
    }

    @Test
    func gitFailureReferencesPointAtTheRecordCoreWrote() {
        let action = UserAction(id: "vcs.pull", surface: .toolbar, operationID: "action-op")
        let user = GitExecutionContext(operationID: "execution-op", source: .user, action: action)
        let background = GitExecutionContext(operationID: "execution-op", source: .background, action: action)
        #expect(user.traceOperationID == "action-op")
        #expect(background.traceOperationID == "execution-op")
        #expect(GitExecutionContext(operationID: "execution-op", source: .user, action: nil).traceOperationID == "execution-op")

        let invocation = GitProcessInvocation(arguments: ["pull"], standardOutput: "", standardError: "", exitCode: 1)
        let failed = GitProcessResult(output: "", exitCode: 1, invocations: [invocation])
        let process = GitService.failureReference(failed, execution: user)
        #expect(process == LogRecordReference(channel: "vcs/git", event: VcsGitCommandFailed.id, op: "action-op"))
        let request = GitService.failureReference(nil, execution: background)
        #expect(request == LogRecordReference(channel: "app/core", event: AppCoreRequestFailed.id, op: "execution-op"))
        #expect(GitService.failureReference(GitProcessResult(output: "", exitCode: 0, invocations: [invocation]),
            execution: user) == nil)
        // Every process exited 0, so no Core failure exists for the notification to cite.
        let passed = GitProcessInvocation(arguments: ["stash", "push"], standardOutput: "", standardError: "", exitCode: 0)
        #expect(GitService.failureReference(GitProcessResult(output: "", exitCode: 0, invocations: [passed],
            operationErrorMessage: "Could not restore changes"), execution: user) == nil)
        let rejected = GitService.failureReference(GitProcessResult(output: "", exitCode: 1, invocations: [passed]), execution: user)
        #expect(rejected == LogRecordReference(channel: "app/core", event: AppCoreRequestFailed.id, op: "action-op"))
    }
}
