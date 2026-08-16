import Foundation
import LitheGitModule

@main
struct GitGraphVerification {
    static func main() {
        verifyLinearHistory()
        verifyMergeHistory()
        verifyMissingParent()
        verifyDecorationLabels()
        verifyLaneContinuity()
        print("GitGraph verification passed: linear, merge, truncated parent, labels, and lane continuity")
    }

    /// Lanes are drawn as vertical segments at a lane-derived x, so a branch that
    /// continues past a row must reappear at the very same lane index in the next
    /// row. Packing lanes positionally used to renumber unrelated branches around
    /// every merge, which rendered as broken branch lines.
    private static func verifyLaneContinuity() {
        // Three concurrent branches, so a merge in one has neighbours on both
        // sides whose lanes must not move.
        let layout = GitGraphLayoutService.layout(commits: [
            commit("H", parents: ["G", "E"]),
            commit("G", parents: ["F"]),
            commit("F", parents: ["D"]),
            commit("E", parents: ["D"]),
            commit("D", parents: ["C"]),
            commit("C", parents: ["B"]),
            commit("B", parents: ["A"]),
            commit("A", parents: [])
        ])

        for index in 0..<(layout.rows.count - 1) {
            let row = layout.rows[index]
            let next = layout.rows[index + 1]

            var passedDown = Set<Int>()
            for (lane, colorIndex) in row.incomingLaneColors.enumerated()
            where colorIndex != nil && lane != row.lane {
                passedDown.insert(lane)
            }
            for edge in row.parentEdges {
                if let targetLane = edge.targetLane { passedDown.insert(targetLane) }
            }

            for lane in passedDown.sorted() {
                let isDrawn = lane < next.incomingLaneColors.count
                    && next.incomingLaneColors[lane] != nil
                expect(
                    isDrawn,
                    "lane \(lane) continues past row \(index) (\(row.commit.hash)) but row \(index + 1) leaves it empty"
                )
            }
        }

        // A first parent stays in its child's lane unless another lane already
        // awaits that parent, in which case the branch converges into it.
        expect(
            layout.rows.first(where: { $0.commit.hash == "G" })?.parentEdges.first?.targetLane == 0,
            "a first parent should continue in its child's lane"
        )
        let convergingRow = layout.rows.first { $0.commit.hash == "E" }
        expect(convergingRow?.lane == 1, "E should occupy the lane opened by the merge")
        expect(
            convergingRow?.parentEdges.first?.targetLane == 0,
            "a branch whose first parent is already awaited should converge into that lane"
        )
    }

    private static func verifyLinearHistory() {
        let layout = GitGraphLayoutService.layout(commits: [
            commit("C", parents: ["B"]),
            commit("B", parents: ["A"]),
            commit("A", parents: [])
        ])
        expect(layout.laneCount == 1, "linear history should use one lane")
        expect(layout.rows.map { $0.lane } == [0, 0, 0], "linear history lane positions")
        expect(!layout.hasMissingParents, "linear history should not report missing parents")
    }

    private static func verifyMergeHistory() {
        let layout = GitGraphLayoutService.layout(commits: [
            commit("M", parents: ["D", "C"]),
            commit("D", parents: ["B"]),
            commit("C", parents: ["B"]),
            commit("B", parents: [])
        ])
        expect(layout.laneCount == 2, "merge history should use two lanes")
        expect(layout.rows[0].parentEdges.map { $0.targetLane } == [0, 1], "merge parents should fork")
        expect(layout.rows[1].lane == 0 && layout.rows[2].lane == 1, "branch commits should stay on separate lanes")
        expect(layout.rows[2].parentEdges.first?.targetLane == 0, "branch should converge into first-parent lane")
    }

    private static func verifyMissingParent() {
        let layout = GitGraphLayoutService.layout(commits: [
            commit("HEAD", parents: ["OLDER-COMMIT"])
        ])
        expect(layout.hasMissingParents, "truncated history should report missing parent")
        expect(layout.rows[0].parentEdges.first?.targetLane == nil, "missing parent should terminate at the row edge")
        expect(layout.rows[0].parentEdges.first?.isMissing == true, "missing parent edge should be marked")
    }

    private static func verifyDecorationLabels() {
        let layout = GitGraphLayoutService.layout(commits: [
            commit("A", parents: [], decorations: "HEAD -> main, origin/main, tag: v1.0")
        ])
        let expectedIDs = ["head:HEAD", "branch:main", "remote:origin/main", "tag:v1.0"]
        expect(layout.rows[0].labels.map(\.id) == expectedIDs, "decorations should become typed labels")
    }

    private static func commit(
        _ hash: String,
        parents: [String],
        decorations: String = ""
    ) -> GitCommit {
        GitCommit(
            hash: hash,
            shortHash: String(hash.prefix(7)),
            parentHashes: parents,
            authorName: "lick",
            authorEmail: "lick@example.com",
            date: "2026/08/01 12:00",
            subject: hash,
            decorations: decorations
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("GitGraph verification failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
