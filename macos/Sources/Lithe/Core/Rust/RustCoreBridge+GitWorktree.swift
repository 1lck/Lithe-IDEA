import Foundation
import LitheGitModule

extension RustCoreBridge {
    private struct WorktreeCreationRequest: Encodable {
        struct Reference: Encodable {
            let fullName: String
            let kind: String
        }
        let root: String
        let operation = "createWorktree"
        let worktreeMode: GitWorktreeMode
        let name: String?
        let gitReference: Reference?
        let revision: String?
        let destination: String
        let noCheckout: Bool
    }

    func gitCreateWorktree(_ request: GitWorktreeCreation, at root: URL) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(command: "git.write", payload: WorktreeCreationRequest(
            root: root.standardizedFileURL.path,
            worktreeMode: request.mode,
            name: request.name,
            gitReference: request.reference.map { .init(fullName: $0.fullName, kind: $0.kind.rawValue) },
            revision: request.revision,
            destination: request.destination.standardizedFileURL.path,
            noCheckout: request.noCheckout
        ))
    }
}
