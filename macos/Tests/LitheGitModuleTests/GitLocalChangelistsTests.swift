import Foundation
import Testing
@testable import LitheGitModule

struct GitLocalChangelistsTests {
    private let root = URL(fileURLWithPath: "/workspace/A")

    @Test
    func nativeScopesMatchTheSharedDefaultAndCustomFixture() throws {
        struct Fixture: Decodable {
            let defaultScope: GitWorkspaceCommitPathScope
            let customScope: GitWorkspaceCommitPathScope
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/git/local-changelist-scope-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        var state = GitLocalChangelists()
        state.lists.append(GitLocalChangelist(id: "local", name: "Local config"))
        state.move([change("application.yaml")], to: "local")
        let repositories = [GitWorkspaceRepositoryBinding(id: "A", root: root.path)]
        #expect(state.commitScope(repositories: repositories, changes: []) == fixture.defaultScope)
        state.activeID = "local"
        #expect(state.commitScope(repositories: repositories, changes: []) == fixture.customScope)
        #expect(try JSONDecoder().decode(GitLocalChangelists.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test
    func renameAliasesSurviveCleanStatusWithoutLeakingIntoAnotherWorktree() {
        var state = GitLocalChangelists()
        state.lists.append(GitLocalChangelist(id: "local", name: "Local"))
        state.move([change("application.yaml")], to: "local")
        state.move([change("renamed.yaml")], to: GitLocalChangelists.defaultID)
        let renamed = change("renamed.yaml", original: "application.yaml")
        state.rememberRenames([renamed])
        state.rememberRenames([])
        #expect(state.listID(for: change("renamed.yaml")) == "local")
        let sibling = change("renamed.yaml", at: URL(fileURLWithPath: "/workspace/B"))
        #expect(state.listID(for: sibling) == GitLocalChangelists.defaultID)
        let scope = state.commitScope(repositories: [.init(id: "A", root: root.path)], changes: [])
        #expect(scope.paths["A"] == ["application.yaml", "renamed.yaml"])
        state.move([renamed], to: GitLocalChangelists.defaultID)
        #expect(state.commitScope(repositories: [.init(id: "A", root: root.path)], changes: []).paths.isEmpty)
    }

    @Test
    func movingACopyDoesNotRemoveProtectionFromItsSource() {
        var state = GitLocalChangelists()
        state.lists.append(GitLocalChangelist(id: "local", name: "Local"))
        state.move([change("application.yaml")], to: "local")
        let copy = GitChange(repositoryRoot: root, path: "copy.yaml", originalPath: "application.yaml",
                             indexStatus: "C", workTreeStatus: " ")
        state.move([copy], to: GitLocalChangelists.defaultID)
        #expect(state.listID(for: copy) == GitLocalChangelists.defaultID)
        #expect(state.listID(for: change("application.yaml")) == "local")
    }

    @Test
    func invalidMetadataCannotSilentlyReassignProtectedFiles() {
        var state = GitLocalChangelists()
        state.assignments[root.path] = ["application.yaml": "deleted-list"]
        #expect(!state.isValid)
        state = GitLocalChangelists()
        state.activeID = "missing"
        #expect(!state.isValid)
        state = GitLocalChangelists()
        state.version = 2
        #expect(!state.isValid)
    }

    private func change(_ path: String, original: String? = nil, at repository: URL? = nil) -> GitChange {
        GitChange(repositoryRoot: repository ?? root, path: path, originalPath: original,
                  indexStatus: original == nil ? " " : "R", workTreeStatus: "M")
    }
}
