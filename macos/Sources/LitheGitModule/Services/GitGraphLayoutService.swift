import Foundation

/// Turns a loaded history window into the native graph models. The layout itself —
/// permanent layout, head ordering, colors, filtered topology, lanes, print elements —
/// is Core's `git.graphProjection`; this service builds the request and maps the answer.
package enum GitGraphLayoutService {
    /// The Core request for one loaded window; the whole window is projected in one call.
    package static func request(
        commits: [GitCommit],
        references: [GitReference] = [],
        repositoryCommits: [GitCommit] = [],
        visibleHashes: Set<String>? = nil,
        options: GitGraphDisplayOptions = .compact,
        currentBranch: String? = nil
    ) -> GitGraphProjectionRequest {
        func identities(_ values: [GitCommit]) -> [GitGraphProjectionRequest.Commit] {
            values.map { .init(hash: $0.hash, parentHashes: $0.parentHashes, decorations: $0.decorations) }
        }
        return GitGraphProjectionRequest(
            commits: identities(commits),
            remoteNames: references.filter { $0.kind == .remote }.map(\.shortName),
            repositoryCommits: identities(repositoryCommits),
            visibleHashes: visibleHashes.map { Array($0) },
            displayMode: options.mode,
            currentBranch: currentBranch
        )
    }

    /// Projects one loaded window through Core. `nil` means Core rejected the request.
    package static func layout(
        commits: [GitCommit],
        references: [GitReference] = [],
        repositoryCommits: [GitCommit] = [],
        visibleHashes: Set<String>? = nil,
        options: GitGraphDisplayOptions = .compact,
        currentBranch: String? = nil,
        project: GitGraphProjector
    ) async -> GitGraphLayout? {
        guard !commits.isEmpty else { return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false) }
        let request = request(
            commits: commits, references: references, repositoryCommits: repositoryCommits,
            visibleHashes: visibleHashes, options: options, currentBranch: currentBranch
        )
        guard let response = await project(request), !Task.isCancelled else { return nil }
        return layout(commits: commits, response: response)
    }

    /// Attaches the caller's commits to Core's rows; the first commit of a hash wins.
    package static func layout(commits: [GitCommit], response: GitGraphProjectionResponse) -> GitGraphLayout? {
        var byHash: [String: GitCommit] = [:]
        for commit in commits where byHash[commit.hash] == nil { byHash[commit.hash] = commit }
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(response.rows.count)
        for row in response.rows {
            guard let commit = byHash[row.commitHash] else { return nil }
            rows.append(GitGraphRow(
                commit: commit, lane: row.lane, laneCount: row.laneCount,
                incomingLaneColors: row.incomingLaneColors.map { Optional($0) },
                parentEdges: row.parentEdges.map {
                    GitGraphEdge(id: $0.id, parentHash: $0.parentHash, targetLane: $0.targetLane,
                                 colorIndex: $0.colorId, isMissing: $0.isMissing)
                },
                labels: row.labels.compactMap { label in
                    GitGraphReferenceKind(rawValue: label.kind).map { GitGraphLabel(title: label.title, kind: $0) }
                },
                layoutIndex: row.layoutIndex, nodeColorIndex: row.colorId,
                printElements: row.printElements.map { element in
                    // `<edge id>:<direction>`; both halves of an edge share the edge ID.
                    let edgeID = element.id.lastIndex(of: ":").map { String(element.id[..<$0]) } ?? element.id
                    return GitGraphPrintElement(
                        edgeID: edgeID, position: element.position, adjacentPosition: element.adjacentPosition,
                        direction: element.direction == "down" ? .down : .up, colorIndex: element.colorId,
                        isDotted: element.isDotted, hasArrow: element.hasArrow, isTerminal: element.isTerminal,
                        targetHash: element.targetHash
                    )
                }
            ))
        }
        return GitGraphLayout(
            rows: rows, laneCount: response.laneCount, hasMissingParents: response.hasMissingParents,
            recommendedLaneCount: response.recommendedLaneCount,
            currentBranchHashes: Set(response.currentBranchHashes)
        )
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
}

extension GitFeatureModel {
    /// Projects the loaded history window through Core off the main actor.
    package var graphProjector: GitGraphProjector {
        let service = service
        return { request in await service.corePlan(.graphProjection, request) }
    }
}
