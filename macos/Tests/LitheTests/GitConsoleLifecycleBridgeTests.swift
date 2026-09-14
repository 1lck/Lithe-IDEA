import Foundation
import Testing
import LitheGitModule
@testable import Lithe

@Suite("Git console lifecycle bridge")
struct GitConsoleLifecycleBridgeTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"), arguments: [false, true])
    func featureSettingsPreflightFailureReachesConsoleUnlessCleared(clearDuringOperation: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-settings-console-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "--template=", "-q"], currentDirectoryURL: root)
        try #require(setup.terminationStatus == 0)
        let journal = GitExecutionJournal()
        let preferences = GitExecutionPreferences()
        let core = RustCoreBridge(gitPreferences: preferences, gitExecutionJournal: journal)
        try #require(core.isAvailable)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: core)), executionJournal: journal)
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {}, onGitOperationBegan: {
                // The lifecycle callback orders clearing before the failed Core
                // request without sleeps or racing a background worker.
                if clearDuringOperation { feature.clearGitConsole() }
            })
        await feature.refreshGit()
        await feature.executionSettings.load(at: root)
        let field = try #require(feature.executionSettings.snapshot?.fields.first { $0.key == "pull.rebase" })
        #expect(journal.snapshot.isEmpty, "Successful internal settings reads stay silent")
        var options = GitExecutionOptions()
        options.executable = root.appendingPathComponent("missing-git-executable").path
        preferences.update(options)
        await feature.saveExecutionConfiguration(at: root, field: field, value: "true")
        let error = try #require(feature.executionSettings.errorMessage)
        #expect(journal.runningOperationIDs.isEmpty)
        if clearDuringOperation {
            #expect(feature.gitConsoleEntries.isEmpty && journal.snapshot.isEmpty)
        } else {
            #expect(feature.gitConsoleEntries.count == 1 && journal.snapshot.count == 1)
            let entry = try #require(journal.snapshot.first)
            #expect(feature.gitConsoleEntries.first?.id == entry.id)
            #expect(entry.workingDirectory.standardizedFileURL == root.standardizedFileURL)
            let diagnostic = try #require(entry.operationErrorMessage)
            // Settings join the same message and details inline; the console
            // keeps them on separate lines for diagnostic readability.
            #expect(error == diagnostic.replacingOccurrences(of: "\n", with: ": "))
            #expect(entry.arguments.isEmpty && entry.state == .unconfirmed && !entry.succeeded)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func fetchWithoutRemoteChangesCompletesWithAnExplicitNotice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-fetch-console-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("remote.git")
        let source = directory.appendingPathComponent("source")
        let checkout = directory.appendingPathComponent("checkout")
        func git(_ arguments: [String], at root: URL) async throws {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments, currentDirectoryURL: root)
            try #require(result.terminationStatus == 0)
        }
        try await git(["init", "--bare", "--template=", "--initial-branch=main", remote.path], at: directory)
        for root in [source, checkout] {
            try await git(["init", "--template=", "--initial-branch=main", root.path], at: directory)
            try await git(["remote", "add", "origin", remote.path], at: root)
        }
        try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false",
            "commit", "--allow-empty", "-m", "initial"], at: source)
        try await git(["push", "origin", "main"], at: source)
        let journal = GitExecutionJournal()
        let core = RustCoreBridge(gitExecutionJournal: journal)
        try #require(core.isAvailable)
        var options = GitFetchOptions()
        options.remote = "origin"
        for id in ["first-fetch", "unchanged-fetch"] {
            let result = try core.gitFetch(at: checkout, options: options, operationID: id).get()
            #expect(result.exitCode == 0)
            #expect(journal.runningOperationIDs.isEmpty)
        }
        let entries = journal.snapshot
        try #require(entries.count == 2)
        #expect(entries[0].output.contains("origin/main"))
        #expect(entries[1].output.isEmpty)
        #expect(entries[1].state == .completed && entries[1].succeeded)
        #expect(entries[1].remoteResult?.succeeded == true)
        #expect(entries[1].remoteResult?.updatedCount == 0)
        #expect(entries[1].remoteResult?.deletedCount == 0)
        let presentation = try #require(RustGitOperations(core: core).consolePresentation(GitConsolePresentationRequest(entries: entries, search: "")))
        #expect(presentation.entries[0].notice == nil)
        #expect(presentation.entries[1].notice == "fetchUnchanged")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func sharedJournalRetainsFailureBeforeGitStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-console-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = GitExecutionJournal()
        let preferences = GitExecutionPreferences()
        var options = GitExecutionOptions()
        options.executable = root.appendingPathComponent("missing-git-executable").path
        preferences.update(options)
        let core = RustCoreBridge(gitPreferences: preferences, gitExecutionJournal: journal)
        try #require(core.isAvailable)
        let result = core.gitCommandResult(at: root, arguments: ["fetch", "origin"])
        guard case .failure(let error) = result else {
            Issue.record("A missing executable must fail before starting Git")
            return
        }
        #expect(journal.runningOperationIDs.isEmpty)
        #expect(journal.snapshot.contains { $0.operationErrorMessage?.contains(error.message) == true },
            "The failed request returned \(error.message), but its shared console history is \(journal.snapshot)")
        let failure = try #require(journal.snapshot.first)
        #expect(failure.workingDirectory.standardizedFileURL == root.standardizedFileURL)
        #expect(failure.arguments.isEmpty && failure.state == .unconfirmed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func internalGitHubOriginLookupDoesNotReportAnExecutedFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-origin-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "--template=", "-q"], currentDirectoryURL: root)
        try #require(setup.terminationStatus == 0)
        let journal = GitExecutionJournal()
        let core = RustCoreBridge(gitExecutionJournal: journal)
        try #require(core.isAvailable)
        do {
            _ = try MacGitHubGitOperations(core: core).originRemote(at: root)
            Issue.record("The fixture must have no origin remote")
        } catch {}
        #expect(journal.runningOperationIDs.isEmpty)
        #expect(journal.snapshot.isEmpty,
            "Internal repository discovery produced \(journal.snapshot.map { "\($0.commandLine): exit \($0.exitCode), error \($0.operationErrorMessage ?? "none")" })")
        let configuration = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["config", "remote.origin.url", "https://example.invalid/team/repository.git"], currentDirectoryURL: root)
        try #require(configuration.terminationStatus == 0)
        #expect(try MacGitHubGitOperations(core: core).originRemote(at: root) == "https://example.invalid/team/repository.git")
        #expect(journal.snapshot.isEmpty)
    }
}
