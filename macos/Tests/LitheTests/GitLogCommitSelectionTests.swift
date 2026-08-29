@testable import Lithe
@testable import LitheGitModule
import Testing

struct GitLogCommitSelectionTests {
    @Test
    func navigationFollowsVisibleCommitOrderAndStopsAtTheEdges() throws {
        let commits = [commit("newest"), commit("middle"), commit("oldest")]

        #expect(GitLogCommitSelection.adjacentCommit(
            in: commits,
            selectedHash: "newest",
            offset: 1
        )?.hash == "middle")
        #expect(GitLogCommitSelection.adjacentCommit(
            in: commits,
            selectedHash: "middle",
            offset: -1
        )?.hash == "newest")
        #expect(GitLogCommitSelection.adjacentCommit(
            in: commits,
            selectedHash: "newest",
            offset: -1
        ) == nil)
        #expect(GitLogCommitSelection.adjacentCommit(
            in: commits,
            selectedHash: "oldest",
            offset: 1
        ) == nil)
    }

    @Test
    func navigationUsesAVisibleBoundaryWhenTheSelectionIsNotVisible() throws {
        let commits = [commit("newest"), commit("oldest")]

        #expect(GitLogCommitSelection.adjacentCommit(
            in: commits,
            selectedHash: "filtered-out",
            offset: 1
        )?.hash == "newest")
        #expect(GitLogCommitSelection.adjacentCommit(
            in: commits,
            selectedHash: nil,
            offset: -1
        )?.hash == "oldest")
    }

    private func commit(_ hash: String) -> GitCommit {
        GitCommit(
            hash: hash,
            shortHash: hash,
            parentHashes: [],
            authorName: "Test Author",
            authorEmail: "author@example.com",
            date: "2026-08-28T00:00:00Z",
            subject: hash,
            decorations: ""
        )
    }
}
