import Foundation
import Testing
import LitheCoreContracts
@testable import LitheAgentConversationModule

@MainActor
struct AgentActivityTests {
    @Test func sharedUpstreamWriteEvidenceDistinguishesCreationAndKeepsCompleteText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/acp-events-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(fixture["events"] as? [String: Any])
        for (name, path, old, new, operation) in [
            ("fileEdit", "sample.txt", "before\n" as String?, "after\n", "update"),
            ("claudeFileCreated", "created.txt", nil, "created\n", "add"),
            ("claudeFileWriteUpdated", "updated.txt", "before\n", "after\n", "update")
        ] {
            let event = try #require(events[name] as? [String: Any])
            let update = try #require(event["update"] as? [String: Any])
            var message = AgentConversationMessage(id: name, role: .tool, text: name, toolStatus: .completed)
            message.toolDetails.merge(update)
            let change = try #require(AgentActivity(messages: [message]).files.first)
            #expect(change.path == path)
            #expect(change.canRevert)
            #expect(change.diffs.first?.oldText == old)
            #expect(change.diffs.first?.newText == new)
            #expect(change.diffs.first?.operation == operation)
            message.toolDetails.merge(["status": "completed"])
            #expect(message.toolDetails.diffs == change.diffs)
        }
        var unknown = AgentToolDetails()
        unknown.merge(["_meta": ["claudeCode": ["toolName": "Write", "toolResponse": [
            "type": "update", "filePath": "a.txt", "content": "after", "originalFile": NSNull()]]]])
        #expect(unknown.diffs.isEmpty, "A missing original on update must never be treated as creation")
    }

    @Test func aggregationCountsUniqueFilesAndPreservesStructuredEvidence() throws {
        let first = tool("first", path: "a.txt", old: "old", new: "new", stats: true)
        let second = tool("second", path: "a.txt", old: "new", new: "latest")
        let pending = tool("pending", path: "b.txt", old: "before", new: "after", status: .inProgress)
        var failed = tool("failed", path: "failed.txt", old: "x", new: "y")
        failed.toolStatus = .failed
        var read = tool("read", path: "read.txt", old: "x", new: "y")
        read.toolDetails = AgentToolDetails()
        read.toolDetails.kind = "read"
        read.toolDetails.locations = [.init(path: "read.txt")]
        let activity = AgentActivity(messages: [first, second, pending, failed, read])
        #expect(activity.tools.count == 5)
        #expect(activity.running.map(\.id) == ["pending"])
        #expect(activity.files.map(\.path) == ["a.txt", "b.txt"])
        let file = try #require(activity.files.first)
        #expect(file.toolIDs == ["first", "second"])
        #expect(file.diffs.map(\.oldText) == ["old", "new"])
        #expect(file.canRevert)
        #expect(file.additions == nil, "Missing upstream stats must remain unknown")
        #expect(!activity.files[1].canRevert)
        #expect(first.toolDetails.diffs.first?.additions == 1)
        #expect(first.toolDetails.diffs.first?.deletions == 1)
    }

    @Test func partialUpdatesPreserveDiffAndIncompleteReportsCannotBeReverted() throws {
        var details = tool("edit", path: "a.txt", old: "before", new: "after").toolDetails
        details.merge(["status": "completed", "rawOutput": "saved"])
        #expect(details.diffs.first?.oldText == "before")
        let unknownCreation = tool("unknown", path: "a.txt", old: nil, new: "after")
        #expect(!AgentActivity(messages: [unknownCreation]).files[0].canRevert)
        var creation = unknownCreation
        creation.toolDetails.diffs[0].operation = "add"
        #expect(AgentActivity(messages: [creation]).files[0].canRevert)
        let oversized = tool("large", path: "a.txt", old: "before", new: String(repeating: "x", count: AgentToolDetails.textLimit + 1))
        #expect(oversized.toolDetails.diffs[0].isTruncated)
        #expect(!AgentActivity(messages: [oversized]).files[0].canRevert)
        details.merge(["content": (0..<101).map { _ in ["type": "diff", "path": "a.txt", "oldText": "before", "newText": "after"] }])
        #expect(details.diffs.count == 100)
        #expect(details.diffs.allSatisfy { $0.isTruncated }, "Dropping reported hunks must also disable rollback")
        details.merge(["content": []])
        #expect(details.diffs.isEmpty, "Explicit replacement must remove optimistic evidence")
    }

    @Test func keepingChangesAdvancesTheBaselineAndIsIsolatedByConversation() async throws {
        let connection = AgentConnectionModel(transport: ActivityUnusedTransport())
        seed(connection, session: "one", id: "first", path: "a.txt", old: "A", new: "B")
        seed(connection, session: "two", id: "second-session", path: "a.txt", old: "X", new: "Y")
        let first = try #require(activity(connection, "one").files.first)
        connection.keepFileChanges([first], in: "one")
        #expect(activity(connection, "one").files.isEmpty)
        #expect(activity(connection, "two").files.count == 1)
        seed(connection, session: "one", id: "later", path: "a.txt", old: "B", new: "C")
        let later = try #require(activity(connection, "one").files.first)
        #expect(later.toolIDs == ["tool:later"])
        #expect(later.diffs.first?.oldText == "B", "Kept edits must not be undone by a later rollback")
        connection.keepFileChanges([first], in: "one")
        #expect(activity(connection, "one").files == [later], "A stale review cannot hide a newer version")
        connection.keepFileChanges([later], in: "one")
        #expect(activity(connection, "one").files.isEmpty)
        await connection.stop()
    }

    @Test func rollbackAcknowledgesOnlySuccessfulVersionsInTheCapturedSession() async throws {
        let connection = AgentConnectionModel(transport: ActivityUnusedTransport())
        seed(connection, session: "one", id: "a", path: "a.txt", old: "old", new: "new")
        seed(connection, session: "one", id: "b", path: "b.txt", old: "before", new: "after")
        seed(connection, session: "two", id: "c", path: "a.txt", old: "X", new: "Y")
        let batch = activity(connection, "one").files
        var visited: [String] = []
        await connection.restoreFileChanges(batch, in: "one") { change in
            visited.append(change.path)
            connection.selectSession("two")
            if change.path == "b.txt" { throw ActivityTestError.conflict }
        }
        #expect(visited == ["a.txt", "b.txt"])
        #expect(activity(connection, "one").files.map(\.path) == ["b.txt"])
        #expect(activity(connection, "two").files.count == 1)
        #expect(connection.fileReviewError != nil)
        #expect(connection.fileReviewErrorSessionID == "one")
        #expect(connection.fileReviewSessionID == nil)
        await connection.stop()
    }

    @Test func cancellationAndLaterEvidenceDoNotAcknowledgeUnrestoredChanges() async throws {
        let connection = AgentConnectionModel(transport: ActivityUnusedTransport())
        seed(connection, session: "one", id: "a", path: "a.txt", old: "old", new: "new")
        let batch = activity(connection, "one").files
        await connection.restoreFileChanges(batch, in: "one") { _ in throw CancellationError() }
        #expect(activity(connection, "one").files == batch)
        #expect(connection.fileReviewSessionID == nil)
        await connection.restoreFileChanges(batch, in: "one") { _ in
            seed(connection, session: "one", id: "later", path: "a.txt", old: "old", new: "latest")
        }
        #expect(activity(connection, "one").files.first?.toolIDs == ["tool:later"])
        await connection.stop()
    }

    @Test func stoppingTheConnectionCancelsAndAwaitsItsOwnedRollbackJob() async throws {
        let connection = AgentConnectionModel(transport: ActivityUnusedTransport())
        seed(connection, session: "one", id: "a", path: "a.txt", old: "old", new: "new")
        let batch = activity(connection, "one").files
        let entered = TestGate()
        let release = TestGate()
        let stopping = TestGate()
        let job = Task { @MainActor in
            await connection.restoreFileChanges(batch, in: "one") { _ in
                entered.open()
                let wasReleased = await release.waitUntilOpen()
                try Task.checkCancellation()
                guard wasReleased else { throw ActivityTestError.conflict }
            }
        }
        defer { job.cancel(); entered.open(); release.open(); stopping.open() }
        #expect(await entered.waitUntilOpen(), "Rollback must reach the explicitly controlled boundary")
        #expect(connection.fileReviewSessionID == "one")
        let stop = Task { @MainActor in stopping.open(); await connection.stop() }
        defer { stop.cancel() }
        #expect(await stopping.waitUntilOpen())
        release.open()
        await stop.value
        await job.value
        #expect(connection.fileReviewSessionID == nil)
        #expect(activity(connection, "one").files == batch)
        #expect(connection.fileReviewError == nil)
    }

    private func activity(_ connection: AgentConnectionModel, _ session: String) -> AgentActivity {
        let conversation = connection.conversations[session] ?? AgentConversation()
        return AgentActivity(messages: conversation.messages, reviewed: conversation.reviewedFileChanges)
    }

    private func seed(_ connection: AgentConnectionModel, session: String, id: String, path: String, old: String, new: String) {
        let update: [String: Any] = ["kind": "update", "sessionId": session, "update": [
            "sessionUpdate": "tool_call", "toolCallId": id, "title": "Edit file", "kind": "edit", "status": "completed",
            "content": [["type": "diff", "path": path, "oldText": old, "newText": new]]]]
        let data = try! JSONSerialization.data(withJSONObject: update)
        connection.receive(String(decoding: data, as: UTF8.self))
    }

    private func tool(_ id: String, path: String, old: String?, new: String,
                      status: AgentConversationMessage.ToolStatus = .completed, stats: Bool = false) -> AgentConversationMessage {
        var message = AgentConversationMessage(id: id, role: .tool, text: "Edit \(path)", toolStatus: status)
        var diff: [String: Any] = ["type": "diff", "path": path, "oldText": old as Any, "newText": new]
        if stats { diff["_meta"] = ["jetbrains": ["air": ["diffStats": ["version": 1, "added": 1, "removed": 1]]]] }
        message.toolDetails.merge(["kind": "edit", "locations": [["path": path], ["path": path]], "content": [diff]])
        return message
    }
}

private enum ActivityTestError: Error { case conflict }
@MainActor private struct ActivityUnusedTransport: AgentConversationTransport {
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection {
        throw AgentConversationError.notConnected
    }
}
