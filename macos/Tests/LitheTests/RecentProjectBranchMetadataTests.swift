import Foundation
import Testing
@testable import Lithe

struct RecentProjectBranchMetadataTests {
    @Test
    func readsTheCheckedOutBranchFromHEADWithoutGit() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try write("ref: refs/heads/feat/1316-settings-info-tips\n", to: workspace.appendingPathComponent(".git/HEAD"))

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == "feat/1316-settings-info-tips")
    }

    @Test
    func readsTheBranchThroughAWorktreeGitPointer() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("checkout")
        let gitDirectory = root.appendingPathComponent("repository/.git/worktrees/checkout")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try write("gitdir: ../repository/.git/worktrees/checkout\n", to: workspace.appendingPathComponent(".git"))
        try write("ref: refs/heads/fix/worktree\n", to: gitDirectory.appendingPathComponent("HEAD"))

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == "fix/worktree")
    }

    @Test
    func detachedHEADUsesTheShortCommitID() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try write("0123456789abcdef0123456789abcdef01234567\n", to: workspace.appendingPathComponent(".git/HEAD"))

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == "01234567")
    }

    @Test
    func foldersWithoutARepositoryHaveNoBranch() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == nil)
    }

    @Test
    func recordedBranchIsPersistedAndClearedForFolders() {
        let store = BranchMetadataKeyValueStore()
        let projects = RecentProjectsStore(store: store)
        let repository = URL(fileURLWithPath: "/tmp/lithe-branch-metadata")
        var recorded = projects.record(repository, branch: "feat/metadata", in: [])
        #expect(recorded.first?.branch == "feat/metadata")

        // Reopening a folder that is no longer a repository must not keep the
        // previous branch in the persisted list.
        recorded = projects.record(repository, branch: nil, in: recorded)
        #expect(recorded.first?.branch == nil)
        #expect(projects.load().first?.branch == nil)
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-welcome-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}

private final class BranchMetadataKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
