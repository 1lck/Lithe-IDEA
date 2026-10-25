import Foundation

// Wire DTOs are owned by Rust's git push preview. These native types only carry
// what Core resolved to the push dialog and back to the reviewed push; they do
// not decide where a push goes.

/// How the destination Core resolved relates to the branch's configured upstream.
package enum GitPushTargetKind: String, Codable, Sendable {
    /// The upstream carries the branch's own name.
    case tracking
    /// There is no upstream, so the branch is published under its own name.
    case publish
    /// The upstream has a different name, so the user must pick the destination.
    case divergent
}

/// Destination confirmed for a branch whose upstream has a different name.
package enum GitPushTargetChoice: String, Codable, CaseIterable, Sendable {
    /// Send the branch to the same-named remote branch and repoint its upstream there.
    case publish
    /// Keep updating the differently named upstream branch.
    case upstream
}

package struct GitPushTag: Codable, Equatable, Sendable {
    package let fullName: String
    package let objectId: String

    package init(fullName: String, objectId: String) {
        self.fullName = fullName
        self.objectId = objectId
    }
}

/// The exact destination, its last observed state and the commits one push would
/// send. A reviewed push is validated against these values, so a repository that
/// moved after the dialog opened is rejected instead of pushing unreviewed commits.
package struct GitPushPreview: Equatable, Sendable {
    package let localBranch: String
    package let localHead: String
    package let remote: String
    package let remoteBranch: String
    package let targetKind: GitPushTargetKind
    package let createsRemoteBranch: Bool
    package let remoteTrackingOid: String?
    package let upstream: String?
    package let tags: [GitPushTag]
    package let commits: [GitCommit]
    package let hasMore: Bool

    package init(
        localBranch: String,
        localHead: String,
        remote: String,
        remoteBranch: String,
        targetKind: GitPushTargetKind,
        createsRemoteBranch: Bool,
        remoteTrackingOid: String?,
        upstream: String?,
        tags: [GitPushTag] = [],
        commits: [GitCommit],
        hasMore: Bool = false
    ) {
        self.localBranch = localBranch
        self.localHead = localHead
        self.remote = remote
        self.remoteBranch = remoteBranch
        self.targetKind = targetKind
        self.createsRemoteBranch = createsRemoteBranch
        self.remoteTrackingOid = remoteTrackingOid
        self.upstream = upstream
        self.tags = tags
        self.commits = commits
        self.hasMore = hasMore
    }

    /// `remote/branch`, the branch this push creates or updates.
    package var destination: String { "\(remote)/\(remoteBranch)" }

    /// The values Core compares against the repository when the push runs.
    package var expectation: GitPushExpectation {
        GitPushExpectation(
            localBranch: localBranch,
            localHead: localHead,
            remote: remote,
            remoteBranch: remoteBranch,
            targetKind: targetKind,
            remoteTrackingOid: remoteTrackingOid,
            tags: tags
        )
    }
}

/// Reviewed preview values sent back with the push as `expectedPush`.
package struct GitPushExpectation: Encodable, Equatable, Sendable {
    package let localBranch: String
    package let localHead: String
    package let remote: String
    package let remoteBranch: String
    package let targetKind: GitPushTargetKind
    package let remoteTrackingOid: String?
    package let tags: [GitPushTag]
}

package struct GitPushFailure: Error, Equatable, Sendable {
    package let message: String
    package init(_ message: String) { self.message = GitConsoleRedactor.redact(message) }
}
