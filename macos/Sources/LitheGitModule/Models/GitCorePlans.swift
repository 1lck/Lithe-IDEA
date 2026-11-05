import Foundation

/// Pure Core Git planners. They never start Git or read a repository; the app
/// collects facts, Core decides, and the app executes and presents the result.
package enum GitCorePlanCommand: String, Sendable {
    case normalizeChangeTargets = "git.normalizeChangeTargets"
    case rebasePlanPreview = "git.rebasePlanPreview"
}

// MARK: - git.normalizeChangeTargets

package struct GitChangeTargetsRequest: Encodable, Sendable {
    package struct Target: Encodable, Sendable {
        package let root: String
        package let path: String
        package let untrackedDirectory: Bool
    }
    package let targets: [Target]

    package init(_ changes: [GitChange]) {
        targets = changes.map {
            Target(root: $0.repositoryRoot.standardizedFileURL.path, path: $0.path,
                   untrackedDirectory: $0.isUntrackedDirectory)
        }
    }
}

package struct GitChangeTargetsPlan: Decodable, Sendable {
    package let indices: [Int]
}

// MARK: - git.rebasePlanPreview

package struct GitRebasePreviewRequest: Encodable, Equatable, Sendable {
    package struct Commit: Encodable, Equatable, Sendable {
        package let hash: String
        package let message: String
    }
    package let commits: [Commit]
    package let steps: [GitRebaseStep]
}

/// Messages, start payload, and the first problem for one rebase draft.
package struct GitRebasePlanPreview: Decodable, Sendable, Equatable {
    package struct Issue: Decodable, Sendable, Equatable {
        /// `missingPrecedingCommit`, `emptyRewordMessage`, `emptySquashMessage`, or `invalidMessage`.
        package let code: String
        package let hash: String?
    }
    package struct Row: Decodable, Sendable, Equatable {
        package let hash: String
        package let message: String
    }
    package let issue: Issue?
    /// Draft rows with the message the editor shows for each.
    package let steps: [Row]
    /// Exact steps for `git.rebaseStart`.
    package let startSteps: [GitRebaseStep]
    package let outputCommitCount: Int
}
