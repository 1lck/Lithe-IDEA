import Foundation
import Testing
@testable import Lithe

@Suite("macOS GitHub Git operations")
struct MacGitHubGitOperationsTests {
    @Test
    func detachedWorktreeIsPublishedThroughTheSharedCore() throws {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }
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

        try runGit(["init", "--bare", "-q"], at: remote)
        try runGit(["init", "-q"], at: root)
        try runGit(["config", "user.email", "test@example.com"], at: root)
        try runGit(["config", "user.name", "Lithe Test"], at: root)
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("example.txt"))
        try runGit(["add", "example.txt"], at: root)
        try runGit(["commit", "-qm", "initial"], at: root)
        try runGit(["branch", "-M", "preview"], at: root)
        try runGit(["remote", "add", "origin", remote.path], at: root)
        try runGit(["push", "-qu", "origin", "preview"], at: root)
        try runGit(["switch", "--detach", "-q", "HEAD"], at: root)
        try Data("detached commit\n".utf8).write(to: root.appendingPathComponent("example.txt"))
        try runGit(["add", "example.txt"], at: root)
        try runGit(["commit", "-qm", "detached change"], at: root)
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
        let published = try operations.pullRequestBranchDefaults(at: root)

        #expect(published.head == branch)
        #expect(!published.requiresPublish)
        #expect(!published.isDetached)
        #expect(published.hasUncommittedChanges)
        try runGit(["show-ref", "--verify", "refs/heads/\(branch)"], at: remote)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Git failed"
            throw GitFixtureError.commandFailed(message)
        }
    }
}

private enum GitFixtureError: Error {
    case commandFailed(String)
}
