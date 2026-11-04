import Foundation
import LitheModuleAPI
import LitheCoreContracts

struct MacGitHubGitOperations: GitHubGitOperations, Sendable {
    enum GitError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let message): message
            }
        }
    }

    let core: RustCoreBridge

    func originRemote(at workspaceURL: URL) throws -> String {
        guard let remote = try core.gitRemoteURL(at: workspaceURL, remote: "origin").get() else {
            throw GitError.commandFailed("This project has no origin remote")
        }
        return remote
    }

    func pullRequestBranchDefaults(at workspaceURL: URL) throws -> GitHubPullRequestBranchDefaults {
        let context = try core.gitPullRequestContext(at: workspaceURL).get()
        return GitHubPullRequestBranchDefaults(
            head: context.currentBranch,
            base: context.suggestedBaseBranch,
            requiresPublish: context.requiresPublish,
            isDetached: context.detached,
            suggestedPublishBranch: context.suggestedPublishBranch,
            hasUncommittedChanges: context.hasUncommittedChanges
        )
    }

    func publishPullRequestBranch(named name: String, at workspaceURL: URL) throws {
        let result = try core.gitWriteResult(
            at: workspaceURL,
            operation: "publishBranch",
            name: name
        ).get()
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(
                message.isEmpty ? L10n.string("The branch could not be published") : message
            )
        }
    }

    private struct PreviewRequest: Encodable {
        let root: String
        let number: UInt64
        let headRef: String
        let expectedRepository: GitHubRepository?
    }

    private struct CheckoutRequest: Encodable {
        let root: String
        let number: UInt64
        let headRef: String
        let expectedHead: String
        let expectedBranch: String?
        let expectedOriginFingerprint: String
        let expectedRepository: GitHubRepository?
    }

    func previewCheckout(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL) throws -> GitHubCheckoutPreview {
        do {
            return try core.executeResult(command: "git.pullRequestCheckoutPreview", payload: PreviewRequest(
                root: workspaceURL.standardizedFileURL.path, number: pullRequest.number, headRef: pullRequest.headRef,
                expectedRepository: repository
            )).get()
        } catch {
            // The failed Core request already carries diagnostic details in its execution trace.
            throw GitError.commandFailed(checkoutError(code: error.code, fallback: L10n.string("Could not check the pull request checkout. Check the repository and try again.")))
        }
    }

    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL, preview: GitHubCheckoutPreview) throws {
        let result: RustCoreBridge.GitCommandPayload
        do {
            result = try core.executeResult(command: "git.pullRequestCheckout", payload: CheckoutRequest(
                root: workspaceURL.standardizedFileURL.path, number: pullRequest.number,
                headRef: pullRequest.headRef, expectedHead: preview.head, expectedBranch: preview.currentBranch,
                expectedOriginFingerprint: preview.originFingerprint, expectedRepository: repository
            )).get()
        } catch {
            throw GitError.commandFailed(checkoutError(code: error.code, fallback: error.userMessage))
        }
        if let failure = result.operationError {
            throw GitError.commandFailed(checkoutError(code: failure.code, fallback: failure.userMessage))
        }
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.output) }
    }

    private func checkoutError(code: String?, fallback: String) -> String {
        switch code {
        case "git_branch_exists": L10n.string("The pull request branch already exists. Rename or remove it before retrying.")
        case "git_checkout_changed": L10n.string("The checkout or origin remote changed. Review the pull request checkout again.")
        default: fallback
        }
    }
}
