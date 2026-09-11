import Foundation
@testable import LitheGitModule
import Testing

@Suite("IntelliJ Git graph parity")
struct GitGraphLayoutTests {
    @Test("DFS indices match pinned IntelliJ fixtures", arguments: ["manyNodes", "oneNode", "notFullGraph", "oneNodeNotFullGraph"])
    func upstreamLayout(_ name: String) throws {
        let input = try fixture("layoutBuilder", name, "in")
        let expected = try fixture("layoutBuilder", name, "out").split(separator: "\n").map {
            Int($0.components(separatedBy: "|-")[0])!
        }
        let commits = input.split(separator: "\n").map { line in
            let parts = line.components(separatedBy: "|-")
            return commit(parts[0], parts[1].split(separator: " ").map(String.init))
        }
        #expect(GitGraphLayoutService.layout(commits: commits).rows.map(\.layoutIndex) == expected)
    }

    @Test("Compact positions and half-edge routing match IntelliJ golden outputs",
          arguments: ["oneNode", "manyNodes", "longEdges", "oneUpOneDown1", "oneUpOneDown2"])
    func upstreamPrinting(_ name: String) throws {
        let input = try fixture("elementGenerator", name, "in")
        var commits: [GitCommit] = []
        var visible = Set<String>()
        for line in input.split(separator: "\n") {
            let parts = line.components(separatedBy: "|-")
            let id = String(parts[0].split(separator: "_")[0])
            visible.insert(id)
            var hidden: [GitCommit] = []
            let parents = parts[1].split(separator: " ").map { token -> String in
                let fields = token.split(separator: "_")
                let target = String(fields[0])
                // Git commits only carry direct edges. A hidden intermediate
                // commit recreates the upstream fixture's DOTTED edge naturally.
                if fields[1] == "D" {
                    let hash = "hidden-\(id)-\(target)"
                    hidden.append(commit(hash, [target]))
                    return hash
                }
                return target
            }
            commits.append(commit(id, parents))
            commits.append(contentsOf: hidden)
        }
        let options = GitGraphDisplayOptions(
            longEdgeSize: name == "oneUpOneDown2" ? 10 : 7,
            visiblePartSize: name.hasPrefix("oneUpOneDown") ? 1 : 2,
            edgeWithArrowSize: 10
        )
        let layout = GitGraphLayoutService.layout(commits: commits, visibleHashes: visible, options: options)
        let expected = try fixture("elementGenerator", name, "out").split(separator: "\n").map { line -> String in
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|-")
            // The color callback in JetBrains's fixture uses row numbers.
            // Compare its verbatim geometry/style/arrow oracle, excluding color.
            return parts[0] + "|" + parts[1]
        }.sorted()
        let actual = layout.rows.enumerated().flatMap { row, value -> [String] in
            ["Node|\(row):\(value.lane)"] + value.printElements.map { element in
                let direction = element.direction == .down ? "DOWN" : "UP"
                let arrow = element.hasArrow ? "_ARROW" : ""
                let style = element.isDotted ? "DASHED" : "SOLID"
                return "Edge:\(direction)\(arrow):\(style)|\(row):\(element.position):\(element.adjacentPosition)"
            }
        }.sorted()
        #expect(actual == expected)
        assertContinuity(layout)
    }

    @Test("30-row compact threshold preserves commits and exposes both destinations", arguments: [29, 30, 31])
    func longEdgeBoundary(_ span: Int) throws {
        let commits = longEdge(span)
        let layout = GitGraphLayoutService.layout(commits: commits)
        let arrows = layout.rows.flatMap(\.printElements).filter(\.hasArrow)
        #expect(layout.rows.count == commits.count)
        if span < 30 { #expect(arrows.isEmpty) }
        else {
            #expect(arrows.count == 2)
            #expect(Set(arrows.compactMap(\.targetHash)) == ["0", String(span)])
            #expect(layout.rows[span / 2].laneCount == 1)
        }
        assertContinuity(layout)
    }

    @Test("Expanded mode keeps the 1,000-row safety threshold", arguments: [999, 1_000])
    func expandedBoundary(_ span: Int) {
        let layout = GitGraphLayoutService.layout(commits: longEdge(span), options: .expanded)
        #expect(layout.rows[span / 2].laneCount == (span < 1_000 ? 2 : 1))
        #expect(layout.rows.flatMap(\.printElements).filter(\.hasArrow).count == (span < 1_000 ? 2 : 4))
        assertContinuity(layout)
    }

    @Test("Filtering bridges hidden ancestors without inventing unloaded parents")
    func filterProjection() {
        let commits = [commit("a", ["b"]), commit("b", ["c"]), commit("c", ["d"]), commit("d", [])]
        let layout = GitGraphLayoutService.layout(commits: commits, visibleHashes: ["a", "d"])
        #expect(layout.rows.map(\.commit.hash) == ["a", "d"])
        #expect(layout.laneCount == 1)
        #expect(!layout.hasMissingParents)
        #expect(layout.rows.flatMap(\.printElements).allSatisfy { $0.isDotted })
        #expect(layout.rows[0].parentEdges.map(\.parentHash) == ["d"])
        assertContinuity(layout)
    }

    @Test("Filtered ancestors retain the unloaded boundary and resolve it after paging")
    func filteredMissingParent() throws {
        let page = [commit("a", ["b"]), commit("b", ["c"]), commit("unrelated", [])]
        let lastRow = GitGraphLayoutService.layout(commits: page, visibleHashes: ["a"])
        #expect(lastRow.hasMissingParents)
        #expect(lastRow.rows[0].parentEdges.map(\.parentHash) == ["c"])
        #expect(lastRow.rows[0].parentEdges.allSatisfy { $0.isMissing })
        #expect(lastRow.rows[0].printElements.isEmpty)

        let filtered = GitGraphLayoutService.layout(commits: page, visibleHashes: ["a", "unrelated"])
        #expect(filtered.hasMissingParents)
        let prints = filtered.rows.flatMap(\.printElements)
        #expect(!prints.isEmpty)
        #expect(prints.allSatisfy { $0.isDotted && $0.targetHash == nil })
        #expect(prints.contains { $0.hasArrow && $0.isTerminal })
        assertContinuity(filtered)

        let loaded = page + [commit("c", [])]
        let hiddenRoot = GitGraphLayoutService.layout(commits: loaded, visibleHashes: ["a", "unrelated"])
        #expect(!hiddenRoot.hasMissingParents)
        #expect(hiddenRoot.rows[0].parentEdges.isEmpty)
        let visibleRoot = GitGraphLayoutService.layout(commits: loaded, visibleHashes: ["a", "c"])
        #expect(!visibleRoot.hasMissingParents)
        #expect(visibleRoot.rows[0].parentEdges.map(\.parentHash) == ["c"])
        #expect(visibleRoot.rows.flatMap(\.printElements).allSatisfy { $0.isDotted })
        assertContinuity(visibleRoot)
    }

    @Test("Missing projection deduplicates hidden merge paths and stops at visible ancestors")
    func filteredMissingMergePaths() {
        let commits = [commit("a", ["left", "right", "missing"]), commit("peer", ["left"]),
                       commit("left", ["missing", "missing"]), commit("right", ["missing", "other"]),
                       commit("unrelated", ["unrelated-missing"])]
        let layout = GitGraphLayoutService.layout(commits: commits, visibleHashes: ["a", "peer"])
        #expect(layout.hasMissingParents)
        #expect(layout.rows[0].parentEdges.map(\.parentHash) == ["missing", "other"])
        #expect(layout.rows[1].parentEdges.map(\.parentHash) == ["missing"])
        let direct = layout.rows[0].parentEdges.first { $0.parentHash == "missing" }
        #expect(layout.rows[0].printElements.filter { $0.edgeID == direct?.id }.allSatisfy { !$0.isDotted })

        let stopped = GitGraphLayoutService.layout(commits: [commit("a", ["b"]), commit("b", ["c"]), commit("c", ["missing"])],
                                                   visibleHashes: ["a", "b"])
        #expect(stopped.rows[0].parentEdges.map(\.parentHash) == ["b"])
        #expect(stopped.rows[0].parentEdges.allSatisfy { !$0.isMissing })
        #expect(stopped.rows[1].parentEdges.map(\.parentHash) == ["missing"])
        let unrelated = GitGraphLayoutService.layout(commits: [commit("a", []), commit("hidden", ["missing"])], visibleHashes: ["a"])
        #expect(!unrelated.hasMissingParents)
    }

    @Test("An ended branch gives its column back instead of leaving a hole")
    func compactColumns() {
        let layout = GitGraphLayoutService.layout(commits: [commit("a", ["b", "c"]), commit("b", []), commit("c", ["d"]), commit("d", [])])
        #expect(layout.rows[1].laneCount == 2)
        #expect(layout.rows[2].laneCount == 1)
        #expect(layout.rows[2].lane == 0)
        assertContinuity(layout)
    }

    @Test("Pagination resolves missing parents without fake navigation targets")
    func missingParent() {
        let head = commit("a", ["b", "b"])
        let page = GitGraphLayoutService.layout(commits: [head])
        #expect(page.hasMissingParents)
        #expect(page.rows[0].parentEdges.count == 1)
        #expect(page.rows[0].printElements.isEmpty)
        #expect(page.rows[0].printElements.allSatisfy { $0.targetHash == nil })
        let full = GitGraphLayoutService.layout(commits: [head, commit("b", [])])
        #expect(!full.hasMissingParents)
        #expect(full.rows[0].nodeColorIndex == page.rows[0].nodeColorIndex)
        assertContinuity(full)
    }

    @Test("Empty filters produce no graph or missing-history notice")
    func emptyGraph() {
        #expect(GitGraphLayoutService.layout(commits: []).rows.isEmpty)
        let layout = GitGraphLayoutService.layout(commits: [commit("a", ["b"])], visibleHashes: [])
        #expect(layout.rows.isEmpty)
        #expect(layout.laneCount == 0)
        #expect(!layout.hasMissingParents)
    }

    @Test("5,000 hidden merge boundaries keep only the visible result", arguments: [false, true])
    func filteredMissingParentScaling(_ emptyFilter: Bool) throws {
        // Each merge adds a distinct unloaded parent. Copying every suffix's
        // full set retained ~12.5 million members for a one-row result.
        let count = 5_000
        let history = (0..<count).map { row -> GitCommit in
            var parents = ["missing-\(row)"]
            if row + 1 < count { parents.insert(String(row + 1), at: 0) }
            return commit(String(row), parents)
        }
        let visible: Set<String> = emptyFilter ? [] : ["0"]
        let started = ContinuousClock.now
        let layout = GitGraphLayoutService.layout(commits: history, visibleHashes: visible)
        print("Filtered missing graph 5000, empty=\(emptyFilter): \(ContinuousClock.now - started)")
        if emptyFilter {
            #expect(layout.rows.isEmpty)
            #expect(!layout.hasMissingParents)
        } else {
            #expect(layout.rows.count == 1)
            let row = try #require(layout.rows.first)
            #expect(Set(row.parentEdges.map(\.parentHash)) == Set((0..<count).map { "missing-\($0)" }))
            #expect(row.parentEdges.allSatisfy { $0.isMissing })
            #expect(layout.hasMissingParents)
        }
    }

    @Test("Many visible children reuse a shared hidden chain's boundary")
    func sharedHiddenMissingChain() {
        let count = 2_500
        let heads = (0..<count).map { commit("head-\($0)", ["hidden-0"]) }
        let hidden = (0..<count).map { row -> GitCommit in
            let parent = row + 1 < count ? "hidden-\(row + 1)" : "missing"
            return commit("hidden-\(row)", [parent])
        }
        let layout = GitGraphLayoutService.layout(commits: heads + hidden, visibleHashes: Set(heads.map(\.hash)))
        #expect(layout.rows.count == count)
        #expect(layout.hasMissingParents)
        #expect(layout.rows.allSatisfy { $0.parentEdges.map(\.parentHash) == ["missing"] })
        assertContinuity(layout)
    }

    @Test("Cancellation stops emitting projected missing parents")
    @MainActor
    func cancelledMissingProjection() async {
        let task = Task {
            var emitted: [String] = []
            GitGraphMissingParents.project(
                commits: [commit("a", ["b"]), commit("b", ["missing-a", "missing-b"])],
                byHash: ["a": 0, "b": 1], parents: [[1], []], visible: [0]
            ) { _, hash in
                emitted.append(hash)
                // Cancel at an observable consumer boundary, with no clock or
                // scheduler race. Subsequent endpoints must not be published.
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return emitted
        }
        defer { task.cancel() }
        #expect(await task.value == ["missing-a"])
    }

    @Test("IDEA reference priority seeds main before newer feature tips and inner branch heads")
    func referencePriority() {
        let commits = [commit("feature", ["main"], "HEAD -> feature"),
                       commit("main", ["root"], "refs/heads/main"), commit("root", [])]
        let layout = GitGraphLayoutService.layout(commits: commits)
        #expect(layout.rows.map(\.layoutIndex) == [2, 1, 1])
        let tagged = [commit("tip", ["tag"]), commit("tag", ["root"], "tag: v1"), commit("root", [])]
        #expect(GitGraphLayoutService.layout(commits: tagged).rows.map(\.layoutIndex) == [1, 1, 1])
        let remote = GitReference(fullName: "refs/remotes/upstream/work", shortName: "upstream/work", kind: .remote,
                                  isCurrent: false, upstreamShortName: nil)
        let tips = [commit("local", ["root"], "main"), commit("remote", ["root"], "upstream/work"), commit("root", [])]
        let withRemote = GitGraphLayoutService.layout(commits: tips, references: [remote])
        #expect(withRemote.rows.map(\.layoutIndex) == [2, 1, 1])
        #expect(withRemote.rows[1].labels.first?.kind == .remote)
        let origin = [commit("other", ["root"], "refs/remotes/upstream/work"),
                      commit("preferred", ["root"], "origin/main"), commit("root", [])]
        #expect(GitGraphLayoutService.layout(commits: origin).rows.map(\.layoutIndex) == [2, 1, 1])
    }

    @Test("Natural reference names preserve IDEA numeric, zero and case tie-breaks")
    func naturalReferenceNames() {
        let names = ["feature10", "feature02", "feature2", "Feature2", "feature1", "feature002", "feature2x"]
        let sorted = names.sorted { GitGraphHeadOrdering.naturalCompare(Array($0.utf16), Array($1.utf16)) < 0 }
        #expect(sorted == ["feature1", "Feature2", "feature2", "feature2x", "feature02", "feature002", "feature10"])
    }

    @Test("Branch scope retains repository head priority and base order")
    func repositoryGraphBeforeScope() {
        let main = commit("main-tip", ["root"], "origin/main")
        let side = commit("side", ["root"], "HEAD -> feature")
        let root = commit("root", [])
        let repository = [main, side, root]
        let scoped = GitGraphLayoutService.layout(commits: [side, root], repositoryCommits: repository)
        let full = GitGraphLayoutService.layout(commits: repository)
        #expect(scoped.rows.map(\.layoutIndex) == [2, 1])
        #expect(scoped.rows.map(\.nodeColorIndex) == Array(full.rows.dropFirst()).map(\.nodeColorIndex))
        let reordered = GitGraphLayoutService.layout(commits: [side, main, root], repositoryCommits: repository)
        #expect(reordered.rows.map(\.commit.hash) == ["main-tip", "side", "root"])
        assertContinuity(reordered)
    }

    @Test("Incomplete or duplicate repository context falls back without dropping visible commits")
    func incompleteRepositoryContext() {
        let values = [commit("tip", ["root"]), commit("root", [])]
        let expected = GitGraphLayoutService.layout(commits: values)
        for context in [[values[1]], [values[0], values[0], values[1]]] {
            let layout = GitGraphLayoutService.layout(commits: values, repositoryCommits: context)
            #expect(layout.rows == expected.rows)
        }
    }

    @Test("Recommended graph width follows weighted edge counts, not the widest row")
    func recommendedWidth() {
        let layout = GitGraphLayoutService.layout(commits: [commit("a", ["c"]), commit("b", ["c"]), commit("c", [])])
        #expect(layout.recommendedLaneCount == 2)
        #expect(GitGraphLayoutService.routingSnapshot(for: layout).recommendedLaneCount == 2)
        let compact = GitGraphLayoutService.layout(commits: longEdge(100))
        let expanded = GitGraphLayoutService.layout(commits: longEdge(100), options: .expanded)
        #expect(compact.recommendedLaneCount == 1)
        #expect(expanded.recommendedLaneCount == 2)
    }

    private func longEdge(_ span: Int) -> [GitCommit] {
        (0...span).map { row -> GitCommit in
            let parents: [String]
            if row == span {
                parents = []
            } else if row == 0 {
                parents = ["1", String(span)]
            } else {
                parents = [String(row + 1)]
            }
            return commit(String(row), parents)
        }
    }

    private func commit(_ hash: String, _ parents: [String], _ decorations: String = "") -> GitCommit {
        GitCommit(hash: hash, shortHash: hash, parentHashes: parents, authorName: "Fixture",
                  authorEmail: "fixture@example.invalid", date: "2026/09/11", subject: hash, decorations: decorations)
    }

    private func fixture(_ group: String, _ name: String, _ suffix: String) throws -> String {
        let root = try #require(Bundle.module.resourceURL)
        return try String(contentsOf: root.appendingPathComponent("Fixtures/GitGraphIDEA/\(group)/\(name)_\(suffix).txt"), encoding: .utf8)
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
