import Foundation
import Testing
import LitheGitModule
@testable import Lithe

@Suite("macOS GitHub Git operations")
struct MacGitHubGitOperationsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func detachedWorktreeIsPublishedThroughTheSharedCore() async throws {
        let journal = GitExecutionJournal()
        let core = RustCoreBridge(gitExecutionJournal: journal)
        try #require(core.isAvailable, "The Git execution integration lane must link Rust Core")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-github-worktree-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-github-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: remote)
        }

        try await runGit(["init", "--bare", "-q"], at: remote)
        try await runGit(["init", "-q"], at: root)
        try await runGit(["config", "user.email", "test@example.com"], at: root)
        try await runGit(["config", "user.name", "Lithe Test"], at: root)
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("example.txt"))
        try await runGit(["add", "example.txt"], at: root)
        try await runGit(["commit", "-qm", "initial"], at: root)
        try await runGit(["branch", "-M", "preview"], at: root)
        try await runGit(["remote", "add", "origin", remote.path], at: root)
        try await runGit(["push", "-qu", "origin", "preview"], at: root)
        try await runGit(["switch", "--detach", "-q", "HEAD"], at: root)
        try Data("detached commit\n".utf8).write(to: root.appendingPathComponent("example.txt"))
        try await runGit(["add", "example.txt"], at: root)
        try await runGit(["commit", "-qm", "detached change"], at: root)
        try Data("uncommitted\n".utf8).write(to: root.appendingPathComponent("example.txt"))

        let operations = MacGitHubGitOperations(core: core)
        let context = try operations.pullRequestBranchDefaults(at: root)

        #expect(context.head == nil)
        #expect(context.base == "preview")
        #expect(context.requiresPublish)
        #expect(context.isDetached)
        #expect(context.hasUncommittedChanges)
        let branch = try #require(context.suggestedPublishBranch)

        try operations.publishPullRequestBranch(named: branch, at: root)
        // No GitFeatureModel context or Console view exists in this workflow.
        // Both publication commands still reach the shared window journal.
        let invocations = journal.snapshot
        #expect(invocations.contains { $0.arguments.contains("switch") })
        #expect(invocations.contains { $0.arguments.contains("push") })
        #expect(invocations.filter { $0.arguments.contains("push") }.allSatisfy { $0.succeeded })
        let published = try operations.pullRequestBranchDefaults(at: root)

        #expect(published.head == branch)
        #expect(!published.requiresPublish)
        #expect(!published.isDetached)
        #expect(published.hasUncommittedChanges)
        try await runGit(["show-ref", "--verify", "refs/heads/\(branch)"], at: remote)
    }

    private func runGit(_ arguments: [String], at directory: URL) async throws {
        let result = try await TestProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: directory
        )
        guard result.terminationStatus == 0 else {
            let message = String(data: result.output, encoding: .utf8) ?? "Git failed"
            throw GitFixtureError.commandFailed(message)
        }
    }
}

private enum GitFixtureError: Error {
    case commandFailed(String)
}
