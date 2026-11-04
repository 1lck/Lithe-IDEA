import Foundation
import Testing
import LitheGitModule
import LitheModuleAPI
@testable import Lithe

@Suite("macOS typed Git lifecycle")
struct MacGitLifecycleLogTests {
    private func event(_ type: String, failed: Bool = false, expectedExit: Bool = false) throws -> GitExecutionEvent {
        var object: [String: Any] = ["operationId": "operation-1", "type": type, "invocationId": 1,
            "arguments": ["fetch", "private-user-reference"], "exitCode": failed ? 1 : 0,
            "expectedExit": expectedExit]
        if type == "requestFinished" {
            object = ["operationId": "operation-1", "type": type]
            if failed { object["error"] = ["code": "cancelled", "message": "private command output"] }
        }
        return try JSONDecoder().decode(GitExecutionEvent.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func realCoreInvocationNamesProduceOneTerminalPerSpan() throws {
        let sink = TypedLogRecorder()
        let adapter = MacGitLifecycleLog(sink: sink)
        for type in ["requestStarted", "started", "finished", "requestFinished", "requestFinished"] {
            adapter.receive(try event(type))
        }
        #expect(sink.events.map { type(of: $0).id } == ["vcs.git.request.started", "vcs.git.command.started",
            "vcs.git.command.finished", "vcs.git.request.finished"])
        #expect(sink.events.allSatisfy { $0.operationID == "operation-1" })
        let command = try #require(sink.events.first { type(of: $0).id == "vcs.git.command.finished" })
        if case .token(let name) = command.fields["command"] { #expect(name == "fetch") }
        else { Issue.record("Missing controlled command name") }
    }

    @Test func expectedNonzeroExitIsAResultAndRequestFailureRemainsFailed() throws {
        let sink = TypedLogRecorder()
        let adapter = MacGitLifecycleLog(sink: sink)
        adapter.receive(try event("requestStarted"))
        adapter.receive(try event("started"))
        adapter.receive(try event("finished", failed: true))
        adapter.receive(try event("requestFinished", failed: true))
        #expect(sink.events.filter { type(of: $0).level == .error }.count == 2)
        let request = try #require(sink.events.last)
        #expect(type(of: request).id == "vcs.git.request.failed")
        if case .token(let code) = request.fields["failure_code"] { #expect(code == "cancelled") }
        else { Issue.record("Core classification was lost") }
        #expect(request.fields["exit_code"] == nil)
        let expected = TypedLogRecorder()
        let expectedAdapter = MacGitLifecycleLog(sink: expected)
        expectedAdapter.receive(try event("started"))
        expectedAdapter.receive(try event("finished", failed: true, expectedExit: true))
        #expect(expected.events.last.map { type(of: $0).id } == "vcs.git.command.finished")
    }
    @Test func preflightFailureRetainsCoreCodeWithoutInventingExitStatus() throws {
        let sink = TypedLogRecorder()
        let adapter = MacGitLifecycleLog(sink: sink)
        adapter.receive(try event("requestStarted"))
        adapter.receive(try event("requestFinished", failed: true))
        let terminal = try #require(sink.events.last)
        #expect(type(of: terminal).id == "vcs.git.request.failed")
        if case .error(let error) = terminal.fields["error"], let failure = error as? LogFailure {
            #expect(failure.code == "cancelled")
            #expect(failure.domain == "git.core")
        } else { Issue.record("Core code was replaced by an NSError number") }
        #expect(terminal.fields["exit_code"] == nil)
    }

}

extension MacGitLifecycleLogTests {
    @Test func emittedFailureReferenceIsReturnedToTheNotificationOwner() throws {
        let sink = TypedLogRecorder()
        let adapter = MacGitLifecycleLog(sink: sink)
        #expect(adapter.receive(try event("requestStarted")) == nil)
        let reference = try #require(adapter.receive(try event("requestFinished", failed: true)))
        #expect(reference == sink.events.last?.reference)
        #expect(reference.op == "operation-1")
        #expect(adapter.receive(try event("requestFinished", failed: true)) == nil)
    }
}
