import Foundation

enum GitGraphLayoutService {
    private struct Lane: Hashable {
        let hash: String
        let colorIndex: Int
    }

    static func layout(commits: [GitCommit]) -> GitGraphLayout {
        guard !commits.isEmpty else {
            return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false)
        }

        let knownHashes = Set(commits.map(\.hash))
        var lanes: [Lane] = []
        var nextColorIndex = 0
        var maximumLaneCount = 0
        var hasMissingParents = false
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let currentLane: Int
            if let existingLane = lanes.firstIndex(where: { $0.hash == commit.hash }) {
                currentLane = existingLane
            } else {
                currentLane = lanes.count
                lanes.append(Lane(hash: commit.hash, colorIndex: nextColorIndex))
                nextColorIndex += 1
            }

            let incomingColors = lanes.map(\.colorIndex)
            let currentColorIndex = lanes[currentLane].colorIndex

            lanes.remove(at: currentLane)

            for (parentIndex, parentHash) in commit.parentHashes.enumerated() {
                guard knownHashes.contains(parentHash) else {
                    hasMissingParents = true
                    continue
                }
                guard !lanes.contains(where: { $0.hash == parentHash }) else { continue }
                let insertionIndex = min(currentLane + parentIndex, lanes.count)
                let colorIndex: Int
                if parentIndex == 0 {
                    colorIndex = currentColorIndex
                } else {
                    colorIndex = nextColorIndex
                    nextColorIndex += 1
                }
                lanes.insert(Lane(hash: parentHash, colorIndex: colorIndex), at: insertionIndex)
            }

            let parentEdges = commit.parentHashes.enumerated().map { parentIndex, parentHash in
                let targetLane = lanes.firstIndex(where: { $0.hash == parentHash })
                let isMissing = targetLane == nil
                if isMissing { hasMissingParents = true }
                let colorIndex = targetLane.map { lanes[$0].colorIndex }
                    ?? (parentIndex == 0 ? currentColorIndex : nextColorIndex + parentIndex - 1)
                return GitGraphEdge(
                    id: "\(commit.hash):\(parentIndex):\(parentHash)",
                    parentHash: parentHash,
                    targetLane: targetLane,
                    colorIndex: colorIndex,
                    isMissing: isMissing
                )
            }

            let laneCount = max(
                max(incomingColors.count, lanes.count),
                max(currentLane + 1, parentEdges.compactMap(\.targetLane).max().map { $0 + 1 } ?? 0)
            )
            maximumLaneCount = max(maximumLaneCount, laneCount)

            rows.append(
                GitGraphRow(
                    commit: commit,
                    lane: currentLane,
                    laneCount: laneCount,
                    incomingLaneColors: incomingColors,
                    parentEdges: parentEdges,
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
