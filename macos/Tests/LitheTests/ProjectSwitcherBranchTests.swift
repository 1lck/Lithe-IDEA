import Foundation
import LitheGitModule
import Testing
@testable import Lithe

@MainActor
struct ProjectSwitcherBranchTests {
    @Test
    func projectMetadataReadsCurrentBranchWithoutChangingIdentityDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-project-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = GitRepositorySetupFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        model.name = "unsaved name"
        model.email = "unsaved@example.invalid"
        #expect(await model.branch(at: root) == nil)

        // A minimal unborn repository exercises the real Core inspector without
        // commits, network access, or changes to the user's Git configuration.
        let git = root.appendingPathComponent(".git")
        for directory in ["objects", "refs/heads"] {
            try FileManager.default.createDirectory(at: git.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let head = git.appendingPathComponent("HEAD")
        try Data("ref: refs/heads/topic/first\n".utf8).write(to: head)
        #expect(await model.branch(at: root) == "topic/first")
        try Data("ref: refs/heads/topic/second\n".utf8).write(to: head)
        #expect(await model.branch(at: root) == "topic/second")
        #expect(model.name == "unsaved name")
        #expect(model.email == "unsaved@example.invalid")
        #expect(model.state == nil)
        #expect(!model.isBusy)
    }
}
