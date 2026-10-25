import Foundation

// Wire DTOs are owned by Rust's git::workspace_commit. Native projections below
// translate identifiers and status keys for presentation; they do not plan work.
package struct GitWorkspaceRepositoryBinding: Codable, Equatable, Sendable {
    package let id: String
    package let root: String
}

package struct GitWorkspaceCommitRelation: Codable, Equatable, Sendable {
    package let parent: String
    package let child: String
    package let path: String
}

package struct GitWorkspaceCommitPathScope: Codable, Equatable, Sendable {
    package let include: Bool
    package let paths: [String: [String]]
}

/// A destination the user confirmed for a branch whose upstream has a different
/// name. Core compares it with the repository again before pushing, so a changed
/// tracking configuration asks the question again instead of following the old answer.
package struct GitWorkspaceConfirmedPushTarget: Codable, Equatable, Sendable {
    package let choice: GitPushTargetChoice
    package let remote: String
    package let remoteBranch: String

    package init(choice: GitPushTargetChoice, remote: String, remoteBranch: String) {
        self.choice = choice
        self.remote = remote
        self.remoteBranch = remoteBranch
    }
}

/// A repository whose branch tracks a differently named remote branch and has no
/// still-valid confirmation. Both offered destinations live on `remote`.
package struct GitWorkspacePushTargetQuestion: Codable, Equatable, Sendable {
    package let repositoryId: String
    package let localBranch: String
    package let remote: String
    /// Short upstream name such as `origin/release`.
    package let upstream: String
    /// The upstream's branch name on `remote`.
    package let upstreamBranch: String

    package init(repositoryId: String, localBranch: String, remote: String, upstream: String, upstreamBranch: String) {
        self.repositoryId = repositoryId
        self.localBranch = localBranch
        self.remote = remote
        self.upstream = upstream
        self.upstreamBranch = upstreamBranch
    }

    /// The remote branch a confirmed `choice` updates.
    package func confirmation(for choice: GitPushTargetChoice) -> GitWorkspaceConfirmedPushTarget {
        GitWorkspaceConfirmedPushTarget(
            choice: choice,
            remote: remote,
            remoteBranch: choice == .publish ? localBranch : upstreamBranch
        )
    }
}

package struct GitWorkspaceCommitPlan: Codable, Equatable, Sendable {
    package let repositories: [GitWorkspaceRepositoryBinding]
    package let message: String
    package let amend: Bool
    package let push: Bool
    package let includeParentReferences: Bool
    package let isRetry: Bool
    package var pathScope: GitWorkspaceCommitPathScope? = nil
    /// Confirmed destinations by repository ID; Core omits the field when empty. The
    /// plan travels back to Core unchanged on every step, so dropping it here would
    /// make the push ask for a destination again.
    package var pushTargets: [String: GitWorkspaceConfirmedPushTarget]? = nil
    package let orderedIds: [String]
    package let propagatedRelations: [GitWorkspaceCommitRelation]
    package let dependencyRelations: [GitWorkspaceCommitRelation]
    package let states: [String: GitCommitState]
    package let committedIds: Set<String>
    package let pendingPushIds: Set<String>

    func root(_ id: String) -> URL? {
        repositories.first { $0.id == id }.map { URL(fileURLWithPath: $0.root).standardizedFileURL }
    }
}

package struct GitWorkspaceRepositoryResult: Codable, Sendable {
    package var committed: Bool
    package var pushed: Bool
    package var status: String
    package var detail: String

    var displayDetail: String {
        let label: String
        switch status {
        case "pending": label = "Pending"
        case "notIncluded": label = "Not included in the updated plan"
        case "waitingForSubmodule": label = "Waiting for submodule"
        case "committed": label = "Committed"
        case "committedPushPending": label = "Committed; push pending"
        case "committedAndPushed": label = "Committed and pushed"
        case "pushFailed": label = "Committed; push failed"
        case "headAdvanced": label = "HEAD advanced; review before continuing."
        case "outcomeUnknown": label = "Could not verify the commit outcome. Review before retrying."
        default: label = "Repository needs attention"
        }
        return label
    }
}

package struct GitWorkspaceCommitSession: Codable, Sendable {
    package let plan: GitWorkspaceCommitPlan
    package var states: [String: GitCommitState]
    package var results: [String: GitWorkspaceRepositoryResult]
    package var blocked: Set<String>
    package var cursor: Int
    package var commandFailed: Bool
    package var finished: Bool
    package var succeeded: Bool
    package var canRetry: Bool

    var displayedResults: [GitRepositoryCommitResult] {
        results.compactMap { id, result in
            plan.root(id).map { GitRepositoryCommitResult(root: $0, committed: result.committed,
                pushed: result.pushed, detail: result.displayDetail, diagnostic: result.detail) }
        }.sorted { $0.root.path < $1.root.path }
    }
}

package struct GitWorkspaceCommitRequest: Encodable, Sendable {
    package let repositories: [GitWorkspaceRepositoryBinding]
    package let message: String
    package let amend: Bool
    package let push: Bool
    package let includeParentReferences: Bool
    package let previous: GitWorkspaceCommitSession?
    package let reviewed: GitWorkspaceCommitPlan?
    package var pathScope: GitWorkspaceCommitPathScope? = nil
    /// Answers to earlier `pushTargetQuestions`. Core does not inherit them from
    /// `reviewed`, so every rebuilt review must send the answers it already holds.
    package var pushTargets: [String: GitWorkspaceConfirmedPushTarget]? = nil
}

package struct GitWorkspaceCommitPreparation: Codable, Sendable {
    package let session: GitWorkspaceCommitSession
    package let reviewChanged: Bool
    package let requiresConfirmation: Bool
    /// Pushes that still need a destination choice; Core omits the field when empty.
    /// The session must not be stepped while any remain.
    package let pushTargetQuestions: [GitWorkspacePushTargetQuestion]

    package init(
        session: GitWorkspaceCommitSession,
        reviewChanged: Bool,
        requiresConfirmation: Bool,
        pushTargetQuestions: [GitWorkspacePushTargetQuestion] = []
    ) {
        self.session = session
        self.reviewChanged = reviewChanged
        self.requiresConfirmation = requiresConfirmation
        self.pushTargetQuestions = pushTargetQuestions
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(GitWorkspaceCommitSession.self, forKey: .session)
        reviewChanged = try container.decode(Bool.self, forKey: .reviewChanged)
        requiresConfirmation = try container.decode(Bool.self, forKey: .requiresConfirmation)
        pushTargetQuestions = try container.decodeIfPresent([GitWorkspacePushTargetQuestion].self, forKey: .pushTargetQuestions) ?? []
    }
}

package struct GitWorkspaceCommitFailure: Error, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// View identity and native URL projections of the shared review model.
package struct GitSubmoduleCommitPlan: Identifiable, Sendable {
    package let id = UUID()
    package let preparation: GitWorkspaceCommitPreparation
    /// Where each pushing repository's branch goes, resolved by Core when the review
    /// was built. Repositories with a pending or confirmed divergent choice are absent.
    package var pushDestinations: [URL: GitPushPreview] = [:]
    /// Every divergent question raised for this review by repository ID, kept after
    /// it is answered so the choice can still be changed before continuing.
    package var pushChoices: [String: GitWorkspacePushTargetQuestion] = [:]
    var core: GitWorkspaceCommitPlan { preparation.session.plan }
    /// Repositories whose divergent destination has no valid answer yet.
    package var unansweredPushRepositoryIds: Set<String> { Set(preparation.pushTargetQuestions.map(\.repositoryId)) }
    package var needsPushTargetChoice: Bool { !preparation.pushTargetQuestions.isEmpty }
    package func pushQuestion(for root: URL) -> GitWorkspacePushTargetQuestion? {
        core.repositories.first { URL(fileURLWithPath: $0.root).standardizedFileURL == root.standardizedFileURL }
            .flatMap { pushChoices[$0.id] }
    }
    package func confirmedPushTarget(for root: URL) -> GitWorkspaceConfirmedPushTarget? {
        core.repositories.first { URL(fileURLWithPath: $0.root).standardizedFileURL == root.standardizedFileURL }
            .flatMap { core.pushTargets?[$0.id] }
    }
    package var message: String { core.message }
    package var amend: Bool { core.amend }
    package var push: Bool { core.push }
    package var includeParentReferences: Bool { core.includeParentReferences }
    package var isRetry: Bool { core.isRetry }
    package var orderedRoots: [URL] { core.orderedIds.compactMap { core.root($0) } }
    package var committedRoots: Set<URL> { Set(core.committedIds.compactMap { core.root($0) }) }
    package var states: [URL: GitCommitState] {
        Dictionary(uniqueKeysWithValues: core.states.compactMap { id, state in core.root(id).map { ($0, state) } })
    }
    package var propagatedRelations: [GitRepositorySubmoduleRelation] {
        core.propagatedRelations.compactMap { relation in
            guard let parent = core.root(relation.parent), let child = core.root(relation.child) else { return nil }
            return GitRepositorySubmoduleRelation(parent: parent, child: child, path: relation.path)
        }
    }
}
