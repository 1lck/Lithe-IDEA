import Foundation
import Testing
import LitheGitModule
@testable import Lithe

/// The new-branch name rules (`git.branchNamePreview`) and the bounded history
/// walk (`git.historyLocate`) cross the native bridge into Rust Core, so these
/// run the real Core instead of a test double: they pin the JSON field names and
/// the decoded Swift payload the dialogs depend on.
@Suite("Git Core contract bridge", .serialized)
struct GitCoreContractBridgeTests {
    private let core = RustCoreBridge()

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func worktreeComparisonDecodesUntrackedIdentityFromCore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ arguments: [String]) async throws {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments, currentDirectoryURL: root)
            try #require(result.terminationStatus == 0, "git \(arguments) failed")
        }
        try await run(["init", "--template=", "-q"])
        try "before\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await run(["add", "tracked.txt"])
        try await run(["-c", "user.name=Lithe Test", "-c", "user.email=test@example.invalid",
                       "commit", "--no-gpg-sign", "-qm", "initial"])
        try await run(["branch", "-M", "main"])
        try "after\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let reference = GitReference(fullName: "refs/heads/main", shortName: "main", kind: .local,
                                     peelsToCommit: true, isCurrent: true, upstreamShortName: nil)
        let result = try #require(RustGitOperations(core: core).comparison(for: reference, at: root))
        #expect(result.files.map(\.path) == ["new.txt", "tracked.txt"])
        #expect(result.files.map(\.isUntracked) == [true, false])
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func branchNamePreviewDecodesTheSharedContract() throws {
        try #require(core.isAvailable)
        let operations = RustGitOperations(core: core)
        let local = GitReference(fullName: "refs/heads/main", shortName: "main", kind: .local,
                                 peelsToCommit: true, isCurrent: true, upstreamShortName: nil)
        let remote = GitReference(fullName: "refs/remotes/origin/topic", shortName: "origin/topic",
                                  kind: .remote, peelsToCommit: true, isCurrent: false,
                                  upstreamShortName: nil)

        let cleaned = try #require(operations.branchNamePreview(
            rawName: "my new branch",
            requireName: false,
            references: [local, remote],
            reference: remote
        ))
        #expect(cleaned.typingCleanedName == "my-new-branch")
        #expect(cleaned.cleanedName == "my-new-branch")
        #expect(cleaned.initialName == "topic")
        #expect(cleaned.error == nil)

        let conflict = try #require(operations.branchNamePreview(
            rawName: "main",
            requireName: true,
            references: [local, remote],
            reference: nil
        ))
        #expect(conflict.error?.code == .alreadyExists)
        #expect(conflict.error?.name == "main")
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func historyLocateReadsBoundedPagesThroughTheRealCore() async throws {
        try #require(core.isAvailable)
        let operations = RustGitOperations(core: core)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-git-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = URL(fileURLWithPath: "/usr/bin/git")

        func run(_ arguments: [String]) async throws -> String {
            let result = try await TestProcess.run(
                executableURL: git, arguments: arguments, currentDirectoryURL: root)
            try #require(result.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = try await run(["init", "--template=", "-q"])
        for index in 0..<3 {
            _ = try await run([
                "-c", "user.name=Lithe Test", "-c", "user.email=test@example.invalid",
                "commit", "--allow-empty", "--no-gpg-sign", "-q", "-m", "commit \(index)",
            ])
        }
        _ = try await run(["branch", "-M", "main"])
        let hashes = try await run(["rev-list", "HEAD"]).split(separator: "\n").map(String.init)
        try #require(hashes.count == 3)

        let result = try #require(operations.historyLocate(
            at: root,
            reference: GitReference(fullName: "refs/heads/main", shortName: "main", kind: .local,
                                    peelsToCommit: true, isCurrent: true, upstreamShortName: nil),
            target: hashes[2],
            cursor: nil,
            limit: 1,
            maxPages: 3,
            operationID: "git-core-contract-bridge-locate"
        ))
        #expect(result.found)
        #expect(result.pagesLoaded == 3)
        #expect(!result.hasMore)
        #expect(result.nextCursor == nil)
        // Every page read while walking is returned so the caller can append the
        // history between its window and the located commit.
        #expect(result.commits.map(\.hash) == hashes)
    }
}
