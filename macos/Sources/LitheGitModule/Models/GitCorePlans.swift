import Foundation

/// Pure Core Git planners. They never start Git or read a repository; the app
/// collects facts, Core decides, and the app executes and presents the result.
package enum GitCorePlanCommand: String, Sendable {
    case normalizeChangeTargets = "git.normalizeChangeTargets"
    case rebasePlanPreview = "git.rebasePlanPreview"
    case updatePlan = "git.updatePlan"
    case historyWindow = "git.historyWindow"
    case graphProjection = "git.graphProjection"
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

// MARK: - git.updatePlan

/// Facts for `git.updatePlan`; Core owns every Update and Pull rule.
package enum GitUpdatePlanRequest: Encodable, Sendable {
    case route(fullName: String, upstream: String?, isCurrent: Bool, worktrees: [GitWorktree])
    case inspect(
        preflight: GitPullPreflightState,
        interactive: Bool,
        confirmation: Confirmation?
    )

    /// The user's answer to a `chooseStrategy` step, with the inspection they saw.
    package struct Confirmation: Sendable {
        package let strategy: GitPullStrategy
        package let preflight: GitPullPreflightState
        package init(strategy: GitPullStrategy, preflight: GitPullPreflightState) {
            self.strategy = strategy
            self.preflight = preflight
        }
    }

    private struct Facts: Encodable {
        let upstream: String?
        let ahead: Int
        let behind: Int
        let diverged: Bool
        let hasLocalChanges: Bool
        let configuredStrategy: GitPullStrategy?
        init(_ state: GitPullPreflightState) {
            upstream = state.upstream
            ahead = state.ahead
            behind = state.behind
            diverged = state.diverged
            hasLocalChanges = state.hasLocalChanges
            configuredStrategy = state.configuredStrategy
        }
    }

    private struct WorktreeFacts: Encodable {
        let path: String
        let branch: String?
        let isCurrent: Bool
    }

    private struct BranchFacts: Encodable {
        let fullName: String
        let upstream: String?
        let isCurrent: Bool
    }

    private struct ConfirmationFacts: Encodable {
        let strategy: GitPullStrategy
        let preflight: Facts
    }

    private enum Keys: String, CodingKey {
        case stage, branch, worktrees, preflight, interactive, confirmation
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .route(let fullName, let upstream, let isCurrent, let worktrees):
            try container.encode("route", forKey: .stage)
            try container.encode(BranchFacts(fullName: fullName, upstream: upstream, isCurrent: isCurrent), forKey: .branch)
            try container.encode(
                worktrees.map { WorktreeFacts(path: $0.path, branch: $0.isDetached ? nil : $0.branch, isCurrent: $0.isCurrent) },
                forKey: .worktrees
            )
        case .inspect(let preflight, let interactive, let confirmation):
            try container.encode("inspect", forKey: .stage)
            try container.encode(Facts(preflight), forKey: .preflight)
            try container.encode(interactive, forKey: .interactive)
            if let confirmation {
                try container.encode(
                    ConfirmationFacts(strategy: confirmation.strategy, preflight: Facts(confirmation.preflight)),
                    forKey: .confirmation
                )
            }
        }
    }
}

/// The next step of a branch Update. Hosts localize blockers and execute steps.
package struct GitUpdatePlan: Decodable, Sendable, Equatable {
    /// `blocked`, `fastForwardReference`, `inspect`, `chooseStrategy`, or `pull`.
    package let step: String
    /// `noUpstream`, `localChanges`, `upToDate`, `notFastForward`, or `stateChanged`.
    package let blocker: String?
    /// Worktree path to update in; `nil` means the repository root of the request.
    package let checkout: String?
    package let expectedBranch: String?
    package let upstream: String?
    package let interactive: Bool?
    package let strategy: GitPullStrategy?
}

// MARK: - git.historyWindow

/// One `git.historyWindow` operation over commit identities in display order.
package enum GitHistoryWindowRequest: Encodable, Sendable {
    case refreshPlan(loadedCount: Int, pageSize: Int, preserveLoaded: Bool)
    case extendPlan(previous: [String], page: [String], canContinue: Bool)
    case mergePage(window: [String], page: [String], pageHasMore: Bool)
    case reconcileSelection(window: [String], selected: [String], focused: String?, anchor: String?)

    private enum Keys: String, CodingKey {
        case operation, loadedCount, pageSize, preserveLoaded, previous, page, canContinue
        case window, pageHasMore, selected, focused, anchor
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .refreshPlan(let loadedCount, let pageSize, let preserveLoaded):
            try container.encode("refreshPlan", forKey: .operation)
            try container.encode(loadedCount, forKey: .loadedCount)
            try container.encode(pageSize, forKey: .pageSize)
            try container.encode(preserveLoaded, forKey: .preserveLoaded)
        case .extendPlan(let previous, let page, let canContinue):
            try container.encode("extendPlan", forKey: .operation)
            try container.encode(previous, forKey: .previous)
            try container.encode(page, forKey: .page)
            try container.encode(canContinue, forKey: .canContinue)
        case .mergePage(let window, let page, let pageHasMore):
            try container.encode("mergePage", forKey: .operation)
            try container.encode(window, forKey: .window)
            try container.encode(page, forKey: .page)
            try container.encode(pageHasMore, forKey: .pageHasMore)
        case .reconcileSelection(let window, let selected, let focused, let anchor):
            try container.encode("reconcileSelection", forKey: .operation)
            try container.encode(window, forKey: .window)
            try container.encode(selected, forKey: .selected)
            try container.encodeIfPresent(focused, forKey: .focused)
            try container.encodeIfPresent(anchor, forKey: .anchor)
        }
    }
}

/// Union of the `git.historyWindow` answers; each operation fills its own fields.
package struct GitHistoryWindowPlan: Decodable, Sendable, Equatable {
    package let limit: Int?
    package let extensionLimit: Int?
    package let append: [Int]?
    package let hasMore: Bool?
    package let selected: [String]?
    package let focused: String?
    package let anchor: String?
}
