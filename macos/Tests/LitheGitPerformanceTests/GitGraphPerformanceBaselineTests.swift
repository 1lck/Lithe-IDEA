import LitheGitModule
import LitheGitPerformanceSupport
import Testing

@Suite("Git graph performance baseline", .serialized)
struct GitGraphPerformanceBaselineTests {
    @Test("The synthetic history is deterministic and child-before-parent")
    func syntheticHistoryIsDeterministic() {
        let first = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)
        let second = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)

        #expect(first == second)
        #expect(SyntheticGitGraphFixture.parentsFollowChildren(in: first))
        #expect(first.reduce(0) { $0 + $1.parentHashes.count } == 1_299)
    }

    @Test("The 1,000-commit graph preserves the initial work baseline")
    func oneThousandCommitLayoutBaseline() {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 1_000)
        let layout = GitGraphLayoutService.layout(commits: commits)

        #expect(GitGraphStructureBaseline(layout: layout) == .expected(commitCount: 1_000))
        #expect(
            GitGraphStructureBaseline.signature(of: layout)
                == GitGraphStructureBaseline.expectedSignature(commitCount: 1_000)
        )
        #expect(layout.rows.map(\.commit.hash) == commits.map(\.hash))
        #expect(GitGraphStructureBaseline.hasContinuousLanes(layout))
    }

    @Test("The 5,000-commit graph scales within the committed work envelope")
    func fiveThousandCommitLayoutBaseline() {
        let commits = SyntheticGitGraphFixture.mergeHeavy(commitCount: 5_000)
        let layout = GitGraphLayoutService.layout(commits: commits)

        #expect(SyntheticGitGraphFixture.parentsFollowChildren(in: commits))
        #expect(GitGraphStructureBaseline(layout: layout) == .expected(commitCount: 5_000))
        #expect(
            GitGraphStructureBaseline.signature(of: layout)
                == GitGraphStructureBaseline.expectedSignature(commitCount: 5_000)
        )
        #expect(layout.rows.map(\.commit.hash) == commits.map(\.hash))
        #expect(GitGraphStructureBaseline.hasContinuousLanes(layout))
    }
}
