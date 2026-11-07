import Foundation
import LitheGitTestSupport
@testable import LitheGitModule
import Testing

/// Layout rules belong to Rust Core (`git.graphProjection`); its tests and
/// `shared/fixtures/git/graph-projection-v1.json` define them. These tests run the real linked
/// Core and assert how the macOS models carry its answer.
@Suite("Git graph through Core")
struct GitGraphLayoutTests {
    @Test("A linear history stays in one lane and keeps its commits and labels")
    func linear() throws {
        let commits = [commit("C", ["B"], "HEAD -> main"), commit("B", ["A"]), commit("A", [])]
        let layout = GitGraphCoreTestSupport.layout(commits: commits)
        #expect(layout.rows.map(\.commit.hash) == ["C", "B", "A"])
        #expect(layout.rows.map(\.lane) == [0, 0, 0])
        #expect(layout.laneCount == 1)
        #expect(!layout.hasMissingParents)
        #expect(layout.rows[0].labels.map(\.id) == ["head:HEAD", "branch:main"])
        #expect(layout.rows[0].nodeColorIndex == 3_343_801)
        #expect(layout.rows[0].parentEdges.map(\.targetLane) == [0])
        assertContinuity(layout)
    }

    @Test("A merge forks into a second lane and converges into the first-parent lane")
    func merge() {
        let layout = GitGraphCoreTestSupport.layout(commits: [
            commit("M", ["D", "C"]), commit("D", ["B"]), commit("C", ["B"]), commit("B", [])])
        #expect(layout.laneCount == 2)
        #expect(layout.rows[0].parentEdges.map(\.targetLane) == [0, 1])
        #expect(layout.rows.map(\.lane) == [0, 0, 1, 0])
        #expect(layout.rows[2].parentEdges.first?.targetLane == 0)
        #expect(layout.rows[0].isMerge)
        assertContinuity(layout)
    }

    @Test("A truncated parent is marked missing and has no navigation target")
    func missingParent() {
        let layout = GitGraphCoreTestSupport.layout(commits: [commit("a", ["b", "b"])])
        #expect(layout.hasMissingParents)
        #expect(layout.rows[0].parentEdges.count == 1)
        #expect(layout.rows[0].parentEdges[0].isMissing)
        #expect(layout.rows[0].parentEdges[0].targetLane == nil)
        #expect(layout.rows[0].printElements.allSatisfy { $0.targetHash == nil })
    }

    @Test("Filtering bridges hidden ancestors with dotted edges")
    func filtered() {
        let commits = [commit("a", ["b"]), commit("b", ["c"]), commit("c", ["d"]), commit("d", [])]
        let layout = GitGraphCoreTestSupport.layout(commits: commits, visibleHashes: ["a", "d"])
        #expect(layout.rows.map(\.commit.hash) == ["a", "d"])
        #expect(layout.rows[0].parentEdges.map(\.parentHash) == ["d"])
        let printed: [GitGraphPrintElement] = layout.rows.flatMap { $0.printElements }
        #expect(printed.allSatisfy { $0.isDotted })
        assertContinuity(layout)
        let none = GitGraphCoreTestSupport.layout(commits: commits, visibleHashes: [])
        #expect(none.rows.isEmpty && none.laneCount == 0)
    }

    @Test("A branch scope keeps the repository graph's color and base order")
    func repositoryContext() {
        let main = commit("main-tip", ["root"], "origin/main")
        let side = commit("side", ["root"], "HEAD -> feature")
        let root = commit("root", [])
        let full = GitGraphCoreTestSupport.layout(commits: [main, side, root])
        let scoped = GitGraphCoreTestSupport.layout(commits: [side, root], repositoryCommits: [main, side, root])
        #expect(scoped.rows.map(\.layoutIndex) == [2, 1])
        let scopedColors: [Int] = scoped.rows.map { $0.nodeColorIndex }
        let fullColors: [Int] = full.rows.dropFirst().map { $0.nodeColorIndex }
        #expect(scopedColors == fullColors)
        let reordered = GitGraphCoreTestSupport.layout(commits: [side, main, root], repositoryCommits: [main, side, root])
        #expect(reordered.rows.map(\.commit.hash) == ["main-tip", "side", "root"])
    }

    @Test("Expanded mode keeps a long edge as a full lane; compact mode folds it")
    func displayMode() {
        var commits: [GitCommit] = []
        for row in 0...39 {
            var parents: [String] = []
            if row == 0 { parents = ["1", "39"] } else if row < 39 { parents = [String(row + 1)] }
            commits.append(commit(String(row), parents))
        }
        let compact = GitGraphCoreTestSupport.layout(commits: commits)
        let expanded = GitGraphCoreTestSupport.layout(commits: commits, options: .expanded)
        #expect(compact.rows[20].laneCount == 1)
        #expect(expanded.rows[20].laneCount == 2)
        let arrows: [GitGraphPrintElement] = compact.rows.flatMap { $0.printElements }
        #expect(arrows.filter { $0.hasArrow }.count == 2)
        assertContinuity(compact)
        assertContinuity(expanded)
    }

    @Test("Current branch ancestry follows every merge parent and never guesses")
    func currentBranch() {
        let commits = [commit("head", ["left", "merged"], "HEAD -> main"),
                       commit("other", ["base"], "other"), commit("left", ["base"])]
        let repository = [commit("merged", ["base"]), commit("base", ["missing"])]
        let layout = GitGraphCoreTestSupport.layout(commits: commits, repositoryCommits: repository, currentBranch: "main")
        #expect(layout.currentBranchHashes == ["head", "left", "merged", "base", "missing"])
        #expect(GitGraphCoreTestSupport.layout(commits: commits, repositoryCommits: repository).currentBranchHashes.isEmpty)
        #expect(GitGraphCoreTestSupport.layout(commits: [commit("detached", [], "HEAD")], currentBranch: "main")
            .currentBranchHashes.isEmpty)
    }

    @Test("The request carries identities, remote names, filter and mode")
    func request() throws {
        let remote = GitReference(fullName: "refs/remotes/upstream/work", shortName: "upstream/work", kind: .remote,
                                  peelsToCommit: true, isCurrent: false, upstreamShortName: nil)
        let request = GitGraphLayoutService.request(
            commits: [commit("a", ["b"], "x")], references: [remote], visibleHashes: ["a"], options: .expanded,
            currentBranch: "main")
        let expected = GitGraphProjectionRequest.Commit(hash: "a", parentHashes: ["b"], decorations: "x")
        #expect(request.commits == [expected])
        #expect(request.remoteNames == ["upstream/work"])
        #expect(request.visibleHashes == ["a"])
        #expect(request.displayMode == "expanded")
        #expect(request.currentBranch == "main")
        let ghost = try GitGraphProjectionResponse.ghost()
        #expect(GitGraphLayoutService.layout(commits: [commit("a", [])], response: ghost) == nil)
    }

    private func commit(_ hash: String, _ parents: [String], _ decorations: String = "") -> GitCommit {
        GitCommit(hash: hash, shortHash: hash, parentHashes: parents, authorName: "Fixture",
                  authorEmail: "fixture@example.invalid", date: "2026/09/11", subject: hash, decorations: decorations)
    }

    private func assertContinuity(_ layout: GitGraphLayout) {
        for (row, value) in layout.rows.enumerated() {
            for edge in value.printElements where !edge.isTerminal {
                let next = row + (edge.direction == .down ? 1 : -1)
                #expect(layout.rows.indices.contains(next))
                guard layout.rows.indices.contains(next) else { continue }
                #expect(layout.rows[next].printElements.contains {
                    $0.edgeID == edge.edgeID && $0.direction != edge.direction && !$0.isTerminal
                        && $0.position == edge.adjacentPosition && $0.adjacentPosition == edge.position
                        && $0.colorIndex == edge.colorIndex && $0.isDotted == edge.isDotted
                })
            }
        }
    }
}

private extension GitGraphProjectionResponse {
    static func ghost() throws -> GitGraphProjectionResponse {
        // Core never returns a row for a commit the host did not send.
        try JSONDecoder().decode(GitGraphProjectionResponse.self, from: Data(
            #"{"rows":[{"commitHash":"ghost","lane":0,"laneCount":1,"colorId":0,"layoutIndex":1,"incomingLaneColors":[0],"parentEdges":[],"labels":[],"printElements":[]}],"laneCount":1,"recommendedLaneCount":1,"hasMissingParents":false,"currentBranchHashes":[]}"#.utf8))
    }
}
