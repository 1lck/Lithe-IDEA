import Foundation
import LitheGitModule

// Rust resolves the push destination for both the preview and the push itself;
// these requests only forward the reviewed values. Contract: git.pushPreview in
// shared/contracts/rust-core-api.md.
extension RustCoreBridge {
    private struct PushReference: Encodable {
        let fullName: String
        let shortName: String
        let kind: String

        init(_ reference: GitReference) {
            fullName = reference.fullName
            shortName = reference.shortName
            kind = reference.kind.rawValue
        }
    }

    private struct PushPreviewRequest: Encodable {
        let root: String
        let gitReference: PushReference
        let pushTarget: String?
    }

    private struct ReviewedPushRequest: Encodable {
        let root: String
        let operation = "push"
        let gitReference: PushReference
        let expectedPush: GitPushExpectation
        let pushTarget: String?
    }

    struct GitPushPreviewPayload: Decodable, Sendable {
        let localBranch: String
        let localHead: String
        let remote: String
        let remoteBranch: String
        let targetKind: GitPushTargetKind
        let createsRemoteBranch: Bool
        let remoteTrackingOid: String?
        let upstream: String?
        let tags: [GitPushTag]
        let commits: [GitHistoryPayload.Commit]
        let hasMore: Bool

        func makeModel() -> GitPushPreview {
            GitPushPreview(
                localBranch: localBranch,
                localHead: localHead,
                remote: remote,
                remoteBranch: remoteBranch,
                targetKind: targetKind,
                createsRemoteBranch: createsRemoteBranch,
                remoteTrackingOid: remoteTrackingOid,
                upstream: upstream,
                tags: tags,
                commits: commits.map {
                    GitCommit(
                        hash: $0.hash,
                        shortHash: $0.shortHash,
                        parentHashes: $0.parentHashes,
                        authorName: $0.authorName,
                        authorEmail: $0.authorEmail,
                        date: $0.date,
                        subject: $0.subject,
                        decorations: $0.decorations
                    )
                },
                hasMore: hasMore
            )
        }
    }

    func gitPushPreview(
        at rootURL: URL,
        reference: GitReference,
        pushTarget: GitPushTargetChoice?
    ) -> Result<GitPushPreviewPayload, CoreCallError> {
        executeResult(
            command: "git.pushPreview",
            payload: PushPreviewRequest(
                root: rootURL.standardizedFileURL.path,
                gitReference: PushReference(reference),
                pushTarget: pushTarget?.rawValue
            )
        )
    }

    func gitReviewedPush(
        at rootURL: URL,
        reference: GitReference,
        preview: GitPushPreview,
        pushTarget: GitPushTargetChoice?
    ) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(
            command: "git.write",
            payload: ReviewedPushRequest(
                root: rootURL.standardizedFileURL.path,
                gitReference: PushReference(reference),
                expectedPush: preview.expectation,
                pushTarget: pushTarget?.rawValue
            )
        )
    }
}

extension RustGitOperations {
    func pushPreview(
        _ reference: GitReference,
        pushTarget: GitPushTargetChoice?,
        at rootURL: URL
    ) -> Result<GitPushPreview, GitPushFailure> {
        core.gitPushPreview(at: rootURL, reference: reference, pushTarget: pushTarget)
            .map { $0.makeModel() }
            .mapError { GitPushFailure($0.userMessage) }
    }

    func pushReviewed(
        _ reference: GitReference,
        preview: GitPushPreview,
        pushTarget: GitPushTargetChoice?,
        at rootURL: URL
    ) -> GitProcessResult? {
        switch core.gitReviewedPush(at: rootURL, reference: reference, preview: preview, pushTarget: pushTarget) {
        case .success(let response): return makeProcessResult(response)
        case .failure(let error): return GitProcessResult(output: error.userMessage, exitCode: 1)
        }
    }
}
