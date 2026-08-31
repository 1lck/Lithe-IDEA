import Foundation
import Testing
@testable import Lithe
@testable import LitheGitModule

@Suite("Git reference operations", .serialized)
struct GitReferenceOperationsTests {
    @Test
    func remoteReferenceWorkflowsUseCompleteIdentityThroughRustCore() async throws {
        let fixture = try await GitReferenceFixture()
        let repository = fixture.repository
        let mainName = try await fixture.git(["branch", "--show-current"])
        let mainReference = GitReference(
            fullName: "refs/heads/\(mainName)",
            shortName: mainName,
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )

        try await fixture.git(["switch", "-q", "-c", "feature"])
        try Data("feature\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try await fixture.git(["commit", "-qam", "feature"])
        try await fixture.git(["update-ref", "refs/remotes/origin/feature", "refs/heads/feature"])
        try await fixture.git(["switch", "-q", mainName])
        try await fixture.git(["branch", "-D", "feature"])

        let remoteReference = GitReference(
            fullName: "refs/remotes/origin/feature",
            shortName: "origin/feature",
            kind: .remote,
            isCurrent: false,
            upstreamShortName: nil
        )
        let operations = RustGitOperations(core: RustCoreBridge())

        let comparison = operations.comparison(
            from: mainReference,
            to: remoteReference,
            at: repository
        )
        #expect(comparison?.files.map(\.path) == ["tracked.txt"])

        let checkoutAndRebase = operations.checkoutAndRebase(remoteReference, at: repository)
        #expect(checkoutAndRebase?.exitCode == 0)
        #expect(try await fixture.git(["branch", "--show-current"]) == "feature")

        try await fixture.git(["switch", "-q", mainName])
        let pull = operations.pullRemoteReference(
            remoteReference,
            strategy: .merge,
            at: repository
        )
        #expect(pull?.exitCode == 0)
        #expect(try String(contentsOf: repository.appendingPathComponent("tracked.txt")) == "feature\n")
    }
}

private final class GitReferenceFixture {
    let repository: URL

    init() async throws {
        repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-git-reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await git(["init", "-q"])
        try await git(["config", "user.email", "tests@lithe.local"])
        try await git(["config", "user.name", "Lithe Tests"])
        try await git(["config", "core.autocrlf", "false"])
        try await git(["remote", "add", "origin", "."])
        try Data("main\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try await git(["add", "tracked.txt"])
        try await git(["commit", "-qm", "initial"])
    }

    deinit {
        try? FileManager.default.removeItem(at: repository)
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        let result = try await TestProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: repository
        )
        guard result.terminationStatus == 0 else {
            throw GitReferenceFixtureError.commandFailed(
                arguments,
                String(decoding: result.output, as: UTF8.self)
            )
        }
        return String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum GitReferenceFixtureError: Error {
    case commandFailed([String], String)
}
