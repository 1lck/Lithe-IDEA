import Foundation

package enum GitGraphLayoutService {
    /// Uses IntelliJ's permanent-layout, visible-graph and print-element rules.
    /// Input stays in Git's child-before-parent order; filtering never mutates it.
    package static func layout(
        commits: [GitCommit],
        references: [GitReference] = [],
        visibleHashes: Set<String>? = nil,
        options: GitGraphDisplayOptions = .compact
    ) -> GitGraphLayout {
        guard !Task.isCancelled else { return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false) }
        let remoteNames = Set(references.filter { $0.kind == .remote }.map(\.shortName))
        let commitLabels = commits.map { labels(from: $0.decorations, remoteNames: remoteNames) }
        let graph = GitGraphProjection(commits: commits, labels: commitLabels, visibleHashes: visibleHashes)
        guard !Task.isCancelled else { return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false) }
        return graph.layout(options: options)
    }

    package static func routingSnapshot(for layout: GitGraphLayout) -> GitGraphRoutingSnapshot {
        GitGraphRoutingSnapshot(
            rows: layout.rows.enumerated().map { index, row in
                GitGraphRoutingRow(
                    rowIndex: index,
                    nodeLane: row.lane,
                    incoming: row.incomingLaneColors.enumerated().compactMap { lane, color in
                        color.map { GitGraphRoutingSegment(lane: lane, colorIndex: $0) }
                    },
                    routes: row.parentEdges.map {
                        GitGraphRoutingRoute(targetLane: $0.targetLane, colorIndex: $0.colorIndex, isMissing: $0.isMissing)
                    },
                    nodeColorIndex: row.nodeColorIndex,
                    isMerge: row.isMerge,
                    printElements: row.printElements
                )
            },
            laneCount: layout.laneCount,
            recommendedLaneCount: layout.recommendedLaneCount
        )
    }

    private static func labels(from decorations: String, remoteNames: Set<String>) -> [GitGraphLabel] {
        decorations
            .split(separator: ",")
            .flatMap { rawValue -> [GitGraphLabel] in
                let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return [] }

                if raw == "HEAD" {
                    return [GitGraphLabel(title: "HEAD", kind: .head)]
                }
                if raw.hasPrefix("HEAD -> ") {
                    let branch = localName(String(raw.dropFirst("HEAD -> ".count)))
                    return [
                        GitGraphLabel(title: "HEAD", kind: .head),
                        GitGraphLabel(title: branch, kind: .branch)
                    ]
                }
                if raw.hasPrefix("tag: ") {
                    return [GitGraphLabel(title: String(raw.dropFirst("tag: ".count)), kind: .tag)]
                }
                if raw.hasPrefix("refs/tags/") {
                    return [GitGraphLabel(title: String(raw.dropFirst("refs/tags/".count)), kind: .tag)]
                }
                if remoteNames.contains(raw) || raw.hasPrefix("origin/") || raw.hasPrefix("refs/remotes/") {
                    let title = raw.hasPrefix("refs/remotes/")
                        ? String(raw.dropFirst("refs/remotes/".count))
                        : raw
                    return [GitGraphLabel(title: title, kind: .remote)]
                }
                return [GitGraphLabel(title: localName(raw), kind: .branch)]
            }
    }

    private static func localName(_ name: String) -> String {
        name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }
}
