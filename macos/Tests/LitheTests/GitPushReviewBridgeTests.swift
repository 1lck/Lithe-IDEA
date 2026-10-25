import Foundation
import Testing
@testable import Lithe
@testable import LitheGitModule

/// The reviewed push crosses the native bridge into Rust Core's `git.pushPreview`
/// and `git.write`, so these run the real Core against a repository with a local
/// bare remote.
@Suite("Git push review bridge", .serialized)
struct GitPushReviewBridgeTests {
    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func differentlyNamedUpstreamNeedsAChoiceAndThePushFollowsTheReview() async throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let fixture = try await GitPushReviewFixture()
        let operations = RustGitOperations(core: core)
        let topic = GitReference(fullName: "refs/heads/topic", shortName: "topic", kind: .local,
                                 isCurrent: true, upstreamShortName: "origin/main")

        let divergent = try operations.pushPreview(topic, pushTarget: nil, at: fixture.repository).get()
        #expect(divergent.targetKind == .divergent)
        #expect(divergent.upstream == "origin/main")
        #expect(divergent.commits.map(\.subject) == ["topic work"])

        let publish = try operations.pushPreview(topic, pushTarget: .publish, at: fixture.repository).get()
        #expect(publish.destination == "origin/topic")
        #expect(publish.createsRemoteBranch)
        #expect(publish.commits.map(\.subject) == ["topic work"])

        let mainBefore = try await fixture.remote(["rev-parse", "refs/heads/main"])
        let result = try #require(operations.pushReviewed(topic, preview: publish, pushTarget: .publish, at: fixture.repository))
        try #require(result.exitCode == 0 && result.operationErrorMessage == nil, "\(result.output)")

        // The reviewed destination was updated, and the upstream branch was left alone.
        #expect(try await fixture.remote(["rev-parse", "refs/heads/topic"]) == publish.localHead)
        #expect(try await fixture.remote(["rev-parse", "refs/heads/main"]) == mainBefore)
        #expect(try await fixture.git(["rev-parse", "--abbrev-ref", "topic@{upstream}"]) == "origin/topic")
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func chosenUpstreamUpdatesTheDifferentlyNamedBranchOnly() async throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let fixture = try await GitPushReviewFixture()
        let operations = RustGitOperations(core: core)
        let topic = GitReference(fullName: "refs/heads/topic", shortName: "topic", kind: .local,
                                 isCurrent: true, upstreamShortName: "origin/main")

        let preview = try operations.pushPreview(topic, pushTarget: .upstream, at: fixture.repository).get()
        #expect(preview.destination == "origin/main")
        let result = try #require(operations.pushReviewed(topic, preview: preview, pushTarget: .upstream, at: fixture.repository))
        try #require(result.exitCode == 0 && result.operationErrorMessage == nil, "\(result.output)")

        #expect(try await fixture.remote(["rev-parse", "refs/heads/main"]) == preview.localHead)
        #expect(try await fixture.remote(["branch", "--list", "topic"]).isEmpty)
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func repositoryThatMovedAfterTheReviewIsNotPushed() async throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let fixture = try await GitPushReviewFixture()
        let operations = RustGitOperations(core: core)
        let topic = GitReference(fullName: "refs/heads/topic", shortName: "topic", kind: .local,
                                 isCurrent: true, upstreamShortName: "origin/main")
        let reviewed = try operations.pushPreview(topic, pushTarget: .publish, at: fixture.repository).get()

        try Data("more\n".utf8).write(to: fixture.repository.appendingPathComponent("extra.txt"))
        try await fixture.git(["add", "extra.txt"])
        try await fixture.git(["commit", "-qm", "unreviewed work"])
        let result = try #require(operations.pushReviewed(topic, preview: reviewed, pushTarget: .publish, at: fixture.repository))

        // Core reports a rejected operation as an operation error rather than a Git exit code.
        #expect(result.operationErrorMessage == "Git push preview is stale; refresh and try again.")
        #expect(try await fixture.remote(["branch", "--list", "topic"]).isEmpty)
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func commitAndPushAsksForTheDestinationAndPushesTheAnsweredOne() async throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let fixture = try await GitPushReviewFixture()
        let operations = RustGitOperations(core: core)
        try Data("staged\n".utf8).write(to: fixture.repository.appendingPathComponent("staged.txt"))
        try await fixture.git(["add", "staged.txt"])
        let binding = GitWorkspaceRepositoryBinding(id: ".", root: fixture.repository.path)
        func request(_ targets: [String: GitWorkspaceConfirmedPushTarget]?) -> GitWorkspaceCommitRequest {
            GitWorkspaceCommitRequest(repositories: [binding], message: "commit and push", amend: false, push: true,
                                      includeParentReferences: false, previous: nil, reviewed: nil, pushTargets: targets)
        }

        let asking = try operations.prepareWorkspaceCommit(request(nil)).get()
        let question = try #require(asking.pushTargetQuestions.first)
        #expect(asking.pushTargetQuestions.count == 1)
        #expect(question == GitWorkspacePushTargetQuestion(repositoryId: ".", localBranch: "topic", remote: "origin",
                                                          upstream: "origin/main", upstreamBranch: "main"))

        let answer = question.confirmation(for: .publish)
        let answered = try operations.prepareWorkspaceCommit(request([".": answer])).get()
        #expect(answered.pushTargetQuestions.isEmpty)
        #expect(answered.session.plan.pushTargets == [".": answer])

        let mainBefore = try await fixture.remote(["rev-parse", "refs/heads/main"])
        var session = answered.session
        var steps = 0
        while !session.finished, steps < 8 {
            session = try operations.stepWorkspaceCommit(session).get()
            steps += 1
        }

        #expect(session.succeeded)
        #expect(try await fixture.remote(["rev-parse", "refs/heads/topic"]) == fixture.git(["rev-parse", "HEAD"]))
        #expect(try await fixture.remote(["rev-parse", "refs/heads/main"]) == mainBefore)
    }
}

/// A working repository whose `topic` branch tracks the differently named
/// `origin/main` on a local bare remote.
private final class GitPushReviewFixture {
    let root: URL
    let repository: URL
    let origin: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-git-push-review-\(UUID().uuidString)", isDirectory: true)
        repository = root.appendingPathComponent("work", isDirectory: true)
        origin = root.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        _ = try await run(["init", "-q", "--bare"], in: origin)
        try await git(["init", "-q", "-b", "main"])
        try await git(["config", "user.email", "tests@lithe.local"])
        try await git(["config", "user.name", "Lithe Tests"])
        try await git(["config", "core.autocrlf", "false"])
        try Data("main\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try await git(["add", "tracked.txt"])
        try await git(["commit", "-qm", "initial"])
        try await git(["remote", "add", "origin", origin.path])
        try await git(["push", "-q", "origin", "main"])
        try await git(["fetch", "-q", "origin"])
        try await git(["switch", "-q", "-c", "topic"])
        try await git(["branch", "-q", "--set-upstream-to=origin/main", "topic"])
        try Data("topic\n".utf8).write(to: repository.appendingPathComponent("topic.txt"))
        try await git(["add", "topic.txt"])
        try await git(["commit", "-qm", "topic work"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        try await run(arguments, in: repository)
    }

    /// Reads the bare remote directly, so assertions do not trust the working copy's
    /// remote-tracking refs.
    @discardableResult
    func remote(_ arguments: [String]) async throws -> String {
        try await run(arguments, in: origin)
    }

    private func run(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await TestProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: directory
        )
        let output = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.terminationStatus == 0 else {
            throw GitPushReviewFixtureError.commandFailed(arguments, output)
        }
        return output
    }
}

private enum GitPushReviewFixtureError: Error {
    case commandFailed([String], String)
}
