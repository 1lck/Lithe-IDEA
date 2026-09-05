import Foundation

package enum GitGraphLayoutService {
    private struct Lane: Hashable {
        let hash: String
        let colorIndex: Int
    }

    /// Lanes are fixed slots rather than a packed list. A branch keeps the same
    /// slot for its whole visible life, because the renderer draws each incoming
    /// lane as a vertical segment at a lane-derived x: shifting a slot index
    /// between two adjacent rows would leave those segments unable to meet, which
    /// reads as a broken branch line. Inserting or removing slots positionally
    /// renumbers every later lane, so a slot is only ever cleared in place and
    /// reused once free.
    package static func layout(commits: [GitCommit]) -> GitGraphLayout {
        guard !commits.isEmpty else {
            return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false)
        }

        let knownHashes = Set(commits.map(\.hash))
        var slots: [Lane?] = []
        var nextColorIndex = 0
        var maximumLaneCount = 0
        var hasMissingParents = false
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let currentLane: Int
            if let existingLane = slots.firstIndex(where: { $0?.hash == commit.hash }) {
                currentLane = existingLane
            } else {
                currentLane = Self.claimSlot(in: &slots)
                slots[currentLane] = Lane(hash: commit.hash, colorIndex: nextColorIndex)
                nextColorIndex += 1
            }

            let incomingColors = slots.map { $0?.colorIndex }
            let currentColorIndex = slots[currentLane]?.colorIndex ?? 0

            // The commit's own line terminates at its node, so the slot is free
            // for a parent to continue in — keeping the first parent on the same x.
            slots[currentLane] = nil

            var edges: [GitGraphEdge] = []
            edges.reserveCapacity(commit.parentHashes.count)

            for (parentIndex, parentHash) in commit.parentHashes.enumerated() {
                guard knownHashes.contains(parentHash) else {
                    hasMissingParents = true
                    edges.append(
                        GitGraphEdge(
                            id: "\(commit.hash):\(parentIndex):\(parentHash)",
                            parentHash: parentHash,
                            targetLane: nil,
                            colorIndex: parentIndex == 0 ? currentColorIndex : nextColorIndex,
                            isMissing: true
                        )
                    )
                    continue
                }

                let targetLane: Int
                let colorIndex: Int
                if let existingLane = slots.firstIndex(where: { $0?.hash == parentHash }) {
                    // The parent is already awaited elsewhere; merge into that lane
                    // instead of opening a second one for the same commit.
                    targetLane = existingLane
                    colorIndex = slots[existingLane]?.colorIndex ?? currentColorIndex
                } else if parentIndex == 0 {
                    targetLane = currentLane
                    colorIndex = currentColorIndex
                    slots[targetLane] = Lane(hash: parentHash, colorIndex: colorIndex)
                } else {
                    targetLane = Self.claimSlot(in: &slots)
                    colorIndex = nextColorIndex
                    nextColorIndex += 1
                    slots[targetLane] = Lane(hash: parentHash, colorIndex: colorIndex)
                }

                edges.append(
                    GitGraphEdge(
                        id: "\(commit.hash):\(parentIndex):\(parentHash)",
                        parentHash: parentHash,
                        targetLane: targetLane,
                        colorIndex: colorIndex,
                        isMissing: false
                    )
                )
            }

            // Trailing empty slots would widen every row's graph gutter for the
            // rest of the log. Trimming only the tail never renumbers a live lane.
            while slots.last == .some(nil) {
                slots.removeLast()
            }

            let laneCount = max(
                max(incomingColors.count, slots.count),
                max(currentLane + 1, edges.compactMap(\.targetLane).max().map { $0 + 1 } ?? 0)
            )
            maximumLaneCount = max(maximumLaneCount, laneCount)

            rows.append(
                GitGraphRow(
                    commit: commit,
                    lane: currentLane,
                    laneCount: laneCount,
                    incomingLaneColors: incomingColors,
                    parentEdges: edges,
                    labels: labels(from: commit.decorations)
                )
            )
        }

        return GitGraphLayout(
            rows: rows,
            laneCount: max(1, maximumLaneCount),
            hasMissingParents: hasMissingParents
        )
    }

    /// Converts the legacy layout into the compact routing snapshot used by
    /// the native surface. No renderer coordinates or view state cross this
    /// boundary.
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
                        GitGraphRoutingRoute(
                            targetLane: $0.targetLane,
                            colorIndex: $0.colorIndex,
                            isMissing: $0.isMissing
                        )
                    }
                )
            },
            laneCount: layout.laneCount
        )
    }

    /// Returns the leftmost free slot, widening the lane set only when every
    /// existing slot is occupied.
    private static func claimSlot(in slots: inout [Lane?]) -> Int {
        if let free = slots.firstIndex(where: { $0 == nil }) { return free }
        slots.append(nil)
        return slots.count - 1
    }

    private static func labels(from decorations: String) -> [GitGraphLabel] {
        decorations
            .split(separator: ",")
            .flatMap { rawValue -> [GitGraphLabel] in
                let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return [] }

                if raw == "HEAD" {
                    return [GitGraphLabel(title: "HEAD", kind: .head)]
                }
                if raw.hasPrefix("HEAD -> ") {
                    let branch = String(raw.dropFirst("HEAD -> ".count))
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
                if raw.hasPrefix("origin/") || raw.hasPrefix("refs/remotes/") {
                    let title = raw.hasPrefix("refs/remotes/")
                        ? String(raw.dropFirst("refs/remotes/".count))
                        : raw
                    return [GitGraphLabel(title: title, kind: .remote)]
                }
                return [GitGraphLabel(title: raw, kind: .branch)]
            }
    }
}
