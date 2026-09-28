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

package struct GitWorkspaceCommitPlan: Codable, Equatable, Sendable {
    package let repositories: [GitWorkspaceRepositoryBinding]
    package let message: String
    package let amend: Bool
    package let push: Bool
    package let includeParentReferences: Bool
    package let isRetry: Bool
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
        return detail.isEmpty ? label : "\(label): \(detail)"
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
                pushed: result.pushed, detail: result.displayDetail) }
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
}

package struct GitWorkspaceCommitPreparation: Codable, Sendable {
    package let session: GitWorkspaceCommitSession
    package let reviewChanged: Bool
    package let requiresConfirmation: Bool
}

package struct GitWorkspaceCommitFailure: Error, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// View identity and native URL projections of the shared review model.
package struct GitSubmoduleCommitPlan: Identifiable, Sendable {
    package let id = UUID()
    package let preparation: GitWorkspaceCommitPreparation
    var core: GitWorkspaceCommitPlan { preparation.session.plan }
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
