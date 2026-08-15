import Foundation
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
        let result = try core.gitCommandResult(
            at: workspaceURL,
            arguments: ["config", "--get", "remote.origin.url"]
        ).get()
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.output.isEmpty ? "This project has no origin remote" : result.output)
        }
        let remote = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { throw GitError.commandFailed("This project has no origin remote") }
        return remote
    }

    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, at workspaceURL: URL) throws {
        let remoteReference = "refs/remotes/origin/pr/\(pullRequest.number)"
        let fetch = try core.gitCommandResult(
            at: workspaceURL,
            arguments: [
                "fetch", "origin",
                "pull/\(pullRequest.number)/head:\(remoteReference)"
            ]
        ).get()
        guard fetch.exitCode == 0 else { throw GitError.commandFailed(fetch.output) }

        let localBranch = "pr/\(pullRequest.number)-\(sanitizedBranchComponent(pullRequest.headRef))"
        let checkout = try core.gitCommandResult(
            at: workspaceURL,
            arguments: ["checkout", "-B", localBranch, remoteReference]
        ).get()
        guard checkout.exitCode == 0 else { throw GitError.commandFailed(checkout.output) }
    }

    private func sanitizedBranchComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let branch = String(result).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return branch.isEmpty ? "head" : branch
    }
}
