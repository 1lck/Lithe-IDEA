import Foundation
import LitheGitModule

package enum SyntheticGitGraphFixture {
    private static let commitsPerBlock = 10

    /// Produces a stable four-lane history without filesystem, subprocess, or
    /// clock input. Each block opens three side branches and converges them at
    /// its oldest commit, keeping the exercised work comparable across runs.
    package static func mergeHeavy(commitCount: Int) -> [GitCommit] {
        precondition(commitCount > 0 && commitCount.isMultiple(of: commitsPerBlock))

        let blockCount = commitCount / commitsPerBlock
        var commits: [GitCommit] = []
        commits.reserveCapacity(commitCount)

        for block in 0..<blockCount {
            let base = block * commitsPerBlock
            let nextBlockHead = block + 1 < blockCount ? hash(base + commitsPerBlock) : nil
            let parentIndexes: [[Int]] = [
                [base + 1, base + 3, base + 5, base + 7],
                [base + 2],
                [base + 9],
                [base + 4],
                [base + 9],
                [base + 6],
                [base + 9],
                [base + 8],
                [base + 9]
            ]

            for offset in 0..<(commitsPerBlock - 1) {
                let index = base + offset
                commits.append(commit(index, parents: parentIndexes[offset].map(hash)))
            }
            commits.append(commit(base + 9, parents: nextBlockHead.map { [$0] } ?? []))
        }

        return commits
    }

    package static func parentsFollowChildren(in commits: [GitCommit]) -> Bool {
        var rowByHash: [String: Int] = [:]
        rowByHash.reserveCapacity(commits.count)
        for (row, commit) in commits.enumerated() {
            guard rowByHash.updateValue(row, forKey: commit.hash) == nil else { return false }
        }
        return commits.enumerated().allSatisfy { row, commit in
            commit.parentHashes.allSatisfy { parent in
                guard let parentRow = rowByHash[parent] else { return false }
                return parentRow > row
            }
        }
    }

    private static func commit(_ index: Int, parents: [String]) -> GitCommit {
        let commitHash = hash(index)
        return GitCommit(
            hash: commitHash,
            shortHash: String(commitHash.prefix(7)),
            parentHashes: parents,
            authorName: "Lithe Performance Fixture",
            authorEmail: "performance-fixture@example.invalid",
            date: "2026/09/04 00:00",
            subject: "Synthetic commit \(index)",
            decorations: index == 0 ? "HEAD -> main, origin/main" : ""
        )
    }

    private static func hash(_ index: Int) -> String {
        String(format: "%040llx", UInt64(index + 1))
    }
}

/// Stable output-shape counters for the synthetic graph fixtures. These values
/// protect lane density and edge structure; optimized timing samples separately
/// monitor execution cost because identical output can come from faster code.
package struct GitGraphStructureBaseline: Codable, Equatable, Sendable {
    package let rowCount: Int
    package let parentEdgeCount: Int
    package let incomingLaneSlotCount: Int
    package let emptyIncomingLaneSlotCount: Int
    package let crossLaneEdgeCount: Int
    package let maximumEdgeSpan: Int
    package let maximumLaneCount: Int
    package let hasMissingParents: Bool

    package init(layout: GitGraphLayout) {
        rowCount = layout.rows.count
        parentEdgeCount = layout.rows.reduce(0) { $0 + $1.parentEdges.count }
        incomingLaneSlotCount = layout.rows.reduce(0) { $0 + $1.incomingLaneColors.count }
        emptyIncomingLaneSlotCount = layout.rows.reduce(0) { partialResult, row in
            partialResult + row.incomingLaneColors.count(where: { $0 == nil })
        }
        crossLaneEdgeCount = layout.rows.reduce(0) { partialResult, row in
            partialResult + row.parentEdges.count(where: { edge in
                edge.targetLane.map { $0 != row.lane } ?? false
            })
        }
        maximumEdgeSpan = layout.rows.reduce(0) { maximum, row in
            max(maximum, row.parentEdges.compactMap(\.targetLane).map { abs($0 - row.lane) }.max() ?? 0)
        }
        maximumLaneCount = layout.laneCount
        hasMissingParents = layout.hasMissingParents
    }

    private init(
        rowCount: Int,
        parentEdgeCount: Int,
        incomingLaneSlotCount: Int,
        emptyIncomingLaneSlotCount: Int,
        crossLaneEdgeCount: Int,
        maximumEdgeSpan: Int,
        maximumLaneCount: Int,
        hasMissingParents: Bool
    ) {
        self.rowCount = rowCount
        self.parentEdgeCount = parentEdgeCount
        self.incomingLaneSlotCount = incomingLaneSlotCount
        self.emptyIncomingLaneSlotCount = emptyIncomingLaneSlotCount
        self.crossLaneEdgeCount = crossLaneEdgeCount
        self.maximumEdgeSpan = maximumEdgeSpan
        self.maximumLaneCount = maximumLaneCount
        self.hasMissingParents = hasMissingParents
    }

    package static func expected(commitCount: Int) -> Self {
        switch commitCount {
        case 1_000:
            Self(
                rowCount: 1_000,
                parentEdgeCount: 1_299,
                incomingLaneSlotCount: 3_400,
                emptyIncomingLaneSlotCount: 600,
                crossLaneEdgeCount: 600,
                maximumEdgeSpan: 3,
                maximumLaneCount: 4,
                hasMissingParents: false
            )
        case 5_000:
            Self(
                rowCount: 5_000,
                parentEdgeCount: 6_499,
                incomingLaneSlotCount: 17_000,
                emptyIncomingLaneSlotCount: 3_000,
                crossLaneEdgeCount: 3_000,
                maximumEdgeSpan: 3,
                maximumLaneCount: 4,
                hasMissingParents: false
            )
        default:
            preconditionFailure("No committed Git graph baseline for \(commitCount) commits")
        }
    }

    package static func expectedSignature(commitCount: Int) -> UInt64 {
        switch commitCount {
        case 1_000: 15_278_530_430_317_338_432
        case 5_000: 7_223_926_406_961_687_604
        default: preconditionFailure("No committed Git graph signature for \(commitCount) commits")
        }
    }

    /// A lane that passes through a row must retain the same color at the next
    /// row; checking only for a non-empty slot would miss accidental lane reuse.
    package static func hasContinuousLanes(_ layout: GitGraphLayout) -> Bool {
        guard layout.rows.count > 1 else { return true }
        for index in 0..<(layout.rows.count - 1) {
            let row = layout.rows[index]
            let next = layout.rows[index + 1]
            var passedDown: [Int: Int] = [:]

            for (lane, colorIndex) in row.incomingLaneColors.enumerated()
            where lane != row.lane {
                guard let colorIndex else { continue }
                passedDown[lane] = colorIndex
            }
            for edge in row.parentEdges where !edge.isMissing {
                guard let targetLane = edge.targetLane else { return false }
                if let existingColor = passedDown[targetLane], existingColor != edge.colorIndex {
                    return false
                }
                passedDown[targetLane] = edge.colorIndex
            }
            if passedDown.contains(where: { lane, colorIndex in
                lane >= next.incomingLaneColors.count || next.incomingLaneColors[lane] != colorIndex
            }) {
                return false
            }
        }
        return true
    }

    /// Stable FNV-1a over a tagged, length-delimited encoding avoids Swift's
    /// randomized Hasher while preserving collection and field boundaries. The
    /// signature covers graph topology and labels, not copied commit metadata.
    package static func signature(of layout: GitGraphLayout) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        func append(_ byte: UInt8) {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        func append(_ integer: Int) {
            withUnsafeBytes(of: Int64(integer).littleEndian) { bytes in
                bytes.forEach(append)
            }
        }
        func append(_ string: String) {
            append(string.utf8.count)
            string.utf8.forEach(append)
        }
        func append(_ optionalInteger: Int?) {
            if let optionalInteger {
                append(1 as UInt8)
                append(optionalInteger)
            } else {
                append(0 as UInt8)
            }
        }

        append(0x01)
        append(layout.rows.count)
        append(0x02)
        append(layout.laneCount)
        append(0x03)
        append(layout.hasMissingParents ? 1 : 0)
        for row in layout.rows {
            append(0x10)
            append(row.commit.hash)
            append(0x11)
            append(row.lane)
            append(0x12)
            append(row.laneCount)
            append(0x13)
            append(row.incomingLaneColors.count)
            for color in row.incomingLaneColors {
                append(color)
            }
            append(0x14)
            append(row.parentEdges.count)
            for edge in row.parentEdges {
                append(0x20)
                append(edge.parentHash)
                append(edge.targetLane)
                append(edge.colorIndex)
                append(edge.isMissing ? 1 : 0)
            }
            append(0x15)
            append(row.labels.count)
            for label in row.labels {
                append(0x30)
                append(label.kind.rawValue)
                append(label.title)
            }
        }
        append(0xff)
        return value
    }
}
