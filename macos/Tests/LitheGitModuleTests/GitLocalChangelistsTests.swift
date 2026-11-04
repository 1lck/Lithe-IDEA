import Foundation
import Testing
@testable import LitheGitModule

struct GitLocalChangelistsTests {
    @Test
    func wireRequestAndResponseMatchTheSharedCoreFixture() throws {
        struct Fixture: Decodable { let response: GitChangelistCoreProjection }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/git/changelists-reducer-v1.json")
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        var state = GitLocalChangelists()
        state.lists += [.init(id: "one", name: "One"), .init(id: "two", name: "Two")]
        state.assignments["/repo"] = ["dir/": "one", "dir/a": "two", "source": "one", "dest": "default"]
        let root = URL(fileURLWithPath: "/repo")
        let changes = ["dir/a", "dir/b"].map { GitChange(repositoryRoot: root, path: $0, originalPath: nil, indexStatus: " ", workTreeStatus: "M") }
        let request = GitChangelistCoreRequest(state: state, changes: changes,
            repositories: [.init(id: "A", root: "/repo")], action: .init(type: "remove", id: "two"))
        let expected = try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["request"] as? NSDictionary)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
        #expect(encoded == expected)
        let projected = try #require(fixture.response.state.local.withMembership(fixture.response.members, for: changes))
        #expect(projected.listID(for: changes[0]) == "default")
        #expect(projected.listID(for: changes[1]) == "one")
        #expect(!fixture.response.scope.include && fixture.response.scope.paths == ["A": ["dir/", "dir/b", "source"]])
        #expect(fixture.response.scope.membership?.activeId == "default")
        #expect(fixture.response.scope.membership?.assignments["A"]?["dir/a"] == "default")
        let scopeRoundTrip = try JSONDecoder().decode(GitWorkspaceCommitPathScope.self, from: JSONEncoder().encode(fixture.response.scope))
        #expect(scopeRoundTrip == fixture.response.scope)
        let saved = try JSONEncoder().encode(projected)
        let reopened = try JSONDecoder().decode(GitLocalChangelists.self, from: saved)
        #expect(reopened.metadataEquals(projected))
        #expect(reopened.projectedMembership.isEmpty)
    }

    @Test
    func missingProjectionNeverTreatsAssignedPathsAsDefault() {
        var state = GitLocalChangelists()
        state.assignments["/repo"] = ["dir/": "local"]
        let change = GitChange(repositoryRoot: URL(fileURLWithPath: "/repo"), path: "dir/a", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        #expect(state.listID(for: change) != GitLocalChangelists.defaultID)
        state.version = 2
        #expect(!state.isValid)
    }
}
