import Foundation

// Wire types for Core's `git.graphProjection`. Core owns lanes, colors, routes, and
// labels (`shared/fixtures/git/graph-projection-v1.json`); the host builds the request
// and turns the response into its drawing models.

package struct GitGraphProjectionRequest: Encodable, Sendable, Equatable {
    package struct Commit: Encodable, Sendable, Equatable {
        package let hash: String
        package let parentHashes: [String]
        package let decorations: String

        package init(hash: String, parentHashes: [String], decorations: String) {
            self.hash = hash
            self.parentHashes = parentHashes
            self.decorations = decorations
        }
    }

    package let commits: [Commit]
    package let remoteNames: [String]
    package let repositoryCommits: [Commit]
    package let visibleHashes: [String]?
    package let displayMode: String
    package let currentBranch: String?

    package init(
        commits: [Commit], remoteNames: [String] = [], repositoryCommits: [Commit] = [],
        visibleHashes: [String]? = nil, displayMode: String = "compact", currentBranch: String? = nil
    ) {
        self.commits = commits
        self.remoteNames = remoteNames
        self.repositoryCommits = repositoryCommits
        self.visibleHashes = visibleHashes
        self.displayMode = displayMode
        self.currentBranch = currentBranch
    }
}

package struct GitGraphProjectionResponse: Decodable, Sendable {
    package struct Label: Decodable, Sendable {
        package let title: String
        package let kind: String
    }

    package struct ParentEdge: Decodable, Sendable {
        package let id: String
        package let parentHash: String
        package let targetLane: Int?
        package let colorId: Int
        package let isMissing: Bool
    }

    package struct PrintElement: Decodable, Sendable {
        package let id: String
        package let position: Int
        package let adjacentPosition: Int
        package let direction: String
        package let colorId: Int
        package let isDotted: Bool
        package let hasArrow: Bool
        package let isTerminal: Bool
        package let targetHash: String?
    }

    package struct Row: Decodable, Sendable {
        package let commitHash: String
        package let lane: Int
        package let laneCount: Int
        package let colorId: Int
        package let layoutIndex: Int
        package let incomingLaneColors: [Int]
        package let parentEdges: [ParentEdge]
        package let labels: [Label]
        package let printElements: [PrintElement]
    }

    package let rows: [Row]
    package let laneCount: Int
    package let recommendedLaneCount: Int
    package let hasMissingParents: Bool
    package let currentBranchHashes: [String]
}

/// Runs one `git.graphProjection` call; `nil` means Core rejected the request.
package typealias GitGraphProjector = @Sendable (GitGraphProjectionRequest) async -> GitGraphProjectionResponse?
