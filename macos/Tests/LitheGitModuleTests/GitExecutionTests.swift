import Foundation
@testable import LitheGitModule
import Testing

struct GitExecutionTests {
    @Test
    func sharedEventFixtureProducesOneCompletedInvocation() throws {
        struct Fixture: Decodable { let events: [GitExecutionEvent] }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/git/execution-events-v1.json"))
        let context = GitExecutionContext(operationID: "fixture")
        for event in try JSONDecoder().decode(Fixture.self, from: data).events { context.receive(event) }
        let entries = context.drainSnapshot()
        #expect(entries?.count == 1)
        #expect(entries?.first?.succeeded == true)
        #expect(entries?.first?.standardError == "Receiving: 100%\n")
        #expect(entries?.first?.standardOutput == "reference updated\n")
    }

    @Test
    func actualStartProgressAndExitRemainDistinctFromThePlan() throws {
        let context = GitExecutionContext(operationID: "operation")
        func receive(_ json: String) throws {
            context.receive(try JSONDecoder().decode(GitExecutionEvent.self, from: Data(json.utf8)))
        }
        try receive(#"{"operationId":"operation","type":"started","invocationId":1,"workingDirectory":"/workspace","arguments":["fetch","--progress"]}"#)
        #expect(context.drainSnapshot()?.last?.state == .running)
        try receive(#"{"operationId":"operation","type":"output","invocationId":1,"stream":"stderr","text":"Receiving: 50%","progress":true}"#)
        let progress = context.drainSnapshot()?.last
        #expect(progress?.progressText == "Receiving: 50%")
        #expect(progress?.standardError == "")
        try receive(#"{"operationId":"operation","type":"output","invocationId":1,"stream":"stderr","text":"updated remote","progress":false}"#)
        try receive(#"{"operationId":"operation","type":"finished","invocationId":1,"exitCode":0,"durationMilliseconds":42}"#)
        let finished = context.drainSnapshot()?.last
        #expect(finished?.succeeded == true)
        #expect(finished?.durationMilliseconds == 42)
        #expect(finished?.standardError == "updated remote\n")
        #expect(finished?.progressText == nil)
        #expect(context.drainSnapshot() == nil)
    }

    @Test
    func cancellationDoesNotInventAnExitStatusOrLoseOutput() {
        let context = GitExecutionContext(operationID: "operation")
        context.receive(GitExecutionEvent(operationId: "operation", type: "started", invocationId: 1,
            workingDirectory: "/workspace", arguments: ["fetch"]))
        context.receive(GitExecutionEvent(operationId: "operation", type: "output", invocationId: 1, stream: "stdout", text: "remote response"))
        context.requestCancellation()
        #expect(context.isCancellationRequested)
        context.receive(GitExecutionEvent(operationId: "operation", type: "finished", invocationId: 1,
            error: .init(code: "cancelled", message: "Operation was cancelled")))
        let record = context.drainSnapshot()?.last
        #expect(record?.state == .unconfirmed)
        #expect(record?.succeeded == false)
        #expect(record?.output.contains("remote response") == true)
        #expect(record?.operationErrorMessage == "Operation was cancelled")
    }

    @Test
    func unrelatedRequestsAndExcessOutputStayBounded() {
        let context = GitExecutionContext(operationID: "operation")
        context.receive(GitExecutionEvent(operationId: "other", type: "started", invocationId: 1, workingDirectory: "/wrong", arguments: ["fetch"]))
        #expect(context.drainSnapshot() == nil)
        context.receive(GitExecutionEvent(operationId: "operation", type: "started", invocationId: 1, workingDirectory: "/workspace", arguments: ["fetch"]))
        for _ in 0..<100 {
            context.receive(GitExecutionEvent(operationId: "operation", type: "output", invocationId: 1, stream: "stdout", text: String(repeating: "x", count: 1024)))
        }
        let record = context.drainSnapshot()?.last
        #expect(record?.isOutputTruncated == true)
        #expect((record?.output.count ?? 0) <= 32_768)
    }
}
