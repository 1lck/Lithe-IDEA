import Foundation
@testable import LitheGitModule
import Testing

struct GitExecutionTests {
    @Test
    func journalRetainsInterleavedOperationsBeforeTheConsoleExists() throws {
        let journal = GitExecutionJournal()
        for (id, command) in [("stage", "add"), ("commit", "commit"), ("branch", "checkout"), ("publish", "push")] {
            journal.receive(GitExecutionEvent(operationId: id, type: "started", invocationId: 1,
                workingDirectory: "/workspace", arguments: [command]))
        }
        // Every request starts at invocation 1. Interleaved output must still
        // update its own command, without requiring an active console view.
        for id in ["publish", "stage", "branch", "commit"] {
            journal.receive(GitExecutionEvent(operationId: id, type: "output", invocationId: 1,
                stream: "stdout", text: id))
            journal.receive(GitExecutionEvent(operationId: id, type: "finished", invocationId: 1, exitCode: 0))
            journal.receive(GitExecutionEvent(operationId: id, type: "requestFinished"))
        }
        let entries = journal.snapshot
        #expect(entries.map(\.arguments) == [["add"], ["commit"], ["checkout"], ["push"]])
        #expect(entries.map(\.output) == ["stage\n", "commit\n", "branch\n", "publish\n"])
        #expect(entries.allSatisfy { $0.succeeded })
    }

    @Test
    func journalClearSuppressesLateInvocationsAndKeepsOtherRepositories() {
        let journal = GitExecutionJournal()
        for (id, root) in [("old", "/workspace"), ("other", "/other")] {
            journal.receive(GitExecutionEvent(operationId: id, type: "started", invocationId: 1,
                workingDirectory: root, arguments: ["commit"]))
        }
        journal.clear(at: URL(fileURLWithPath: "/workspace"))
        journal.receive(GitExecutionEvent(operationId: "old", type: "started", invocationId: 2,
            workingDirectory: "/workspace", arguments: ["push"]))
        journal.receive(GitExecutionEvent(operationId: "old", type: "requestFinished"))
        journal.receive(GitExecutionEvent(operationId: "query", type: "requestStarted"))
        journal.receive(GitExecutionEvent(operationId: "query", type: "requestFinished"))
        #expect(journal.snapshot.map(\.workingDirectory.path) == ["/other"])
        journal.receive(GitExecutionEvent(operationId: "new", type: "started", invocationId: 1,
            workingDirectory: "/workspace", arguments: ["checkout"]))
        journal.receive(GitExecutionEvent(operationId: "new", type: "requestFinished",
            error: .init(code: "cancelled", message: "Operation was cancelled")))
        #expect(journal.snapshot.last?.state == .unconfirmed)
        #expect(journal.snapshot.last?.operationErrorMessage == "Operation was cancelled")
    }

    @Test
    func sharedConsoleProjectionKeepsGlobalOptionsOutOfTheCommandBody() throws {
        struct Case: Decodable {
            let arguments: [String]
            let temporaryConfig: [[String]]
            let displayArguments: [String]
            let globalArguments: [String]
        }
        struct Fixture: Decodable { let cases: [Case] }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/git/console-command-v1.json")))
        for sample in fixture.cases {
            let context = GitExecutionContext(operationID: "console")
            context.receive(GitExecutionEvent(operationId: "console", type: "started",
                temporaryConfig: sample.temporaryConfig, displayArguments: sample.displayArguments,
                globalArguments: sample.globalArguments, invocationId: 1,
                workingDirectory: "/workspace", arguments: sample.arguments))
            let entry = try #require(context.drainSnapshot()?.last)
            #expect(entry.formattedArguments == GitConsoleCommandFormatter.argumentLine(arguments: sample.displayArguments))
            #expect(entry.formattedTemporaryConfiguration == GitConsoleCommandFormatter.argumentLine(arguments: sample.globalArguments))
            #expect(entry.commandLine == GitConsoleCommandFormatter.commandLine(arguments: sample.arguments))
            #expect(entry.withOperationError("later error").formattedArguments == entry.formattedArguments)
            #expect(entry.copyText.contains(entry.commandLine))
        }
    }

    @Test
    func remoteResultPreservesExplicitCountsAndDefaultsMissingMetadata() throws {
        let context = GitExecutionContext(operationID: "operation")
        context.receive(GitExecutionEvent(operationId: "operation", type: "started", invocationId: 1,
            workingDirectory: "/workspace", arguments: ["fetch"]))
        func receiveResult(_ json: String) throws -> GitRemoteOutcome {
            let event = try JSONDecoder().decode(GitExecutionEvent.self, from: Data(json.utf8))
            context.receive(event)
            return try #require(context.drainSnapshot()?.last?.remoteResult)
        }

        let missing = try receiveResult(#"{"operationId":"operation","type":"remoteResult"}"#)
        #expect(missing.updatedReferences.isEmpty)
        #expect(missing.deletedReferences.isEmpty)
        #expect(missing.updatedCount == 0)
        #expect(missing.deletedCount == 0)
        #expect(missing.referencesAvailable)
        #expect(!missing.truncated)

        let inferred = try receiveResult(#"{"operationId":"operation","type":"remoteResult","remote":"origin","succeeded":true,"updatedReferences":["refs/remotes/origin/main"],"deletedReferences":["refs/remotes/origin/old"]}"#)
        #expect(inferred.remote == "origin")
        #expect(inferred.succeeded)
        #expect(inferred.updatedCount == 1)
        #expect(inferred.deletedCount == 1)

        // Truncated or unavailable reference details must not replace the
        // authoritative counts, including an explicitly supplied zero.
        let explicit = try receiveResult(#"{"operationId":"operation","type":"remoteResult","updatedReferences":["refs/remotes/origin/main"],"updatedReferenceCount":0,"deletedReferenceCount":80,"referencesTruncated":true,"referencesAvailable":false}"#)
        #expect(explicit.updatedCount == 0)
        #expect(explicit.deletedCount == 80)
        #expect(explicit.truncated)
        #expect(!explicit.referencesAvailable)
    }

    @Test
    func sharedPolicyFixtureKeepsAuthenticationSeparateFromConsoleAndPreservesRemoteResults() throws {
        struct Fixture: Decodable { let authentication: GitExecutionEvent; let remoteResult: GitExecutionEvent }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/git/execution-policy-v1.json")))
        let context = GitExecutionContext(operationID: "fixture")
        context.receive(fixture.authentication)
        #expect(context.drainSnapshot() == nil)
        #expect(context.drainChallenges().first?.secret == true)
        #expect(context.drainChallenges().isEmpty)
        context.receive(GitExecutionEvent(operationId: "fixture", type: "started", invocationId: 1, workingDirectory: "/workspace", arguments: ["fetch"]))
        context.receive(fixture.remoteResult)
        #expect(context.drainSnapshot()?.last?.remoteResult?.deletedReferences == ["refs/remotes/origin/old"])
        context.receive(fixture.authentication)
        context.receive(GitExecutionEvent(operationId: "fixture", type: "requestFinished"))
        #expect(context.drainChallenges().isEmpty)
    }

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
        #expect(entries?.first?.outputLines.map(\.stream) == [.standardError, .standardOutput])
        #expect(entries?.first?.output == "Receiving: 100%\nreference updated\n")
        #expect(entries?.first?.withOperationError("later failure").outputLines == entries?.first?.outputLines)
    }

    @Test
    func consoleBoundsEmptyRowsAndPreservesLatestStreamOrder() throws {
        let context = GitExecutionContext(operationID: "operation")
        context.receive(GitExecutionEvent(operationId: "operation", type: "started", invocationId: 1,
            workingDirectory: "/workspace", arguments: ["fetch"]))
        for _ in 0..<2_100 {
            context.receive(GitExecutionEvent(operationId: "operation", type: "output", invocationId: 1,
                stream: "stdout", text: ""))
        }
        context.receive(GitExecutionEvent(operationId: "operation", type: "output", invocationId: 1,
            stream: "stderr", text: "remote response"))
        context.receive(GitExecutionEvent(operationId: "operation", type: "output", invocationId: 1,
            stream: "stdout", text: "updated reference"))
        let entry = try #require(context.drainSnapshot()?.last)
        #expect(entry.isOutputTruncated)
        #expect(entry.outputLines.count == 2_000)
        #expect(entry.outputLines.suffix(2).map(\.stream) == [.standardError, .standardOutput])
        #expect(entry.copyText.contains("remote response\nupdated reference\n"))
    }

    @Test
    func expandableTemporaryConfigurationUsesSafeArgumentFormatting() {
        let entry = GitConsoleEntry(workingDirectory: URL(fileURLWithPath: "/workspace"),
            arguments: ["fetch"], output: "", exitCode: 0,
            temporaryConfig: [["credential.helper", "helper with spaces"],
                              ["http.proxy", "https://fixture:password@example.invalid/?token=fake-secret"]])
        #expect(entry.formattedTemporaryConfiguration.hasPrefix("-c 'credential.helper=helper with spaces' -c "))
        #expect(!entry.formattedTemporaryConfiguration.contains("password"))
        #expect(!entry.formattedTemporaryConfiguration.contains("fake-secret"))
        #expect(!entry.copyText.contains("fake-secret"))
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
