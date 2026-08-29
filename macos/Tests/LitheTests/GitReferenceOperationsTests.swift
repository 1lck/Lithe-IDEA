import Foundation
import Testing
@testable import Lithe
@testable import LitheGitModule

@Suite("Git reference operations", .serialized)
struct GitReferenceOperationsTests {
    @Test
    func remoteReferenceWorkflowsUseCompleteIdentityThroughRustCore() throws {
        let fixture = try GitReferenceFixture()
        let repository = fixture.repository
        let mainName = try fixture.git(["branch", "--show-current"])
        let mainReference = GitReference(
            fullName: "refs/heads/\(mainName)",
            shortName: mainName,
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )

        try fixture.git(["switch", "-q", "-c", "feature"])
        try Data("feature\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try fixture.git(["commit", "-qam", "feature"])
        try fixture.git(["update-ref", "refs/remotes/origin/feature", "refs/heads/feature"])
        try fixture.git(["switch", "-q", mainName])
        try fixture.git(["branch", "-D", "feature"])

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
        #expect(try fixture.git(["branch", "--show-current"]) == "feature")

        try fixture.git(["switch", "-q", mainName])
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

    init() throws {
        repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-git-reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q"])
        try git(["config", "user.email", "tests@lithe.local"])
        try git(["config", "user.name", "Lithe Tests"])
        try git(["config", "core.autocrlf", "false"])
        try git(["remote", "add", "origin", "."])
        try Data("main\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"])
        try git(["commit", "-qm", "initial"])
    }

    deinit {
        try? FileManager.default.removeItem(at: repository)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repository
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw GitReferenceFixtureError.commandFailed(
                arguments,
                String(decoding: error, as: UTF8.self)
            )
        }
        return String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum GitReferenceFixtureError: Error {
    case commandFailed([String], String)
}
