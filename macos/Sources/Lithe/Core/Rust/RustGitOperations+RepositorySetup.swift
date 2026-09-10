import Foundation
import LitheGitModule

extension RustGitOperations {
    private struct SetupRequest: Encodable {
        let root: String
        let scope: GitIdentityScope
    }

    private struct IdentityRequest: Encodable {
        let root: String
        let scope: GitIdentityScope
        let key: GitIdentityField
        let value: String?
    }

    func repositorySetup(at root: URL, scope: GitIdentityScope) -> Result<GitRepositorySetup, GitSetupFailure> {
        core.executeResult(command: "git.repositorySetup", payload: SetupRequest(root: root.path, scope: scope))
            .mapError { GitSetupFailure($0.userMessage) }
    }

    func initializeRepository(at root: URL) -> Result<GitRepositorySetup, GitSetupFailure> {
        core.executeResult(command: "git.initialize", payload: SetupRequest(root: root.path, scope: .local))
            .mapError { GitSetupFailure($0.userMessage) }
    }

    func configureIdentity(at root: URL, scope: GitIdentityScope, field: GitIdentityField, value: String?) -> Result<GitRepositorySetup, GitSetupFailure> {
        core.executeResult(command: "git.configureIdentity", payload: IdentityRequest(root: root.path, scope: scope, key: field, value: value))
            .mapError { GitSetupFailure($0.userMessage) }
    }
}
