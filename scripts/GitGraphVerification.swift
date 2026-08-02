import Foundation

@main
struct GitGraphVerification {
    static func main() {
        verifyLinearHistory()
        verifyMergeHistory()
        verifyMissingParent()
        verifyDecorationLabels()
        print("GitGraph verification passed: linear, merge, truncated parent, and labels")
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
        let expected = [
            GitGraphLabel(title: "HEAD", kind: .head),
            GitGraphLabel(title: "main", kind: .branch),
            GitGraphLabel(title: "origin/main", kind: .remote),
            GitGraphLabel(title: "v1.0", kind: .tag)
        ]
        expect(layout.rows[0].labels == expected, "decorations should become typed labels")
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
