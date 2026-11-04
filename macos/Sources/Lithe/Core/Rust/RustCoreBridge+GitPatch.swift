import Foundation
import LitheGitModule

extension RustCoreBridge {
    private struct GitFileContextRequest: Encodable {
        let root: String
        let path: String
    }

    func gitFileContext(fileURL: URL, relativeTo rootURL: URL) -> GitFileContext? {
        let result: Result<GitFileContext, CoreCallError> = executeResult(
            command: "git.resolveFileContext", payload: GitFileContextRequest(
                root: rootURL.standardizedFileURL.path,
                path: fileURL.standardizedFileURL.path
            )
        )
        return try? result.get()
    }

    private struct ShelfRequest: Encodable {
        let root: String
        let action: String
        let phase: GitShelfPhase?
        let layer: GitShelfLayer?
        let snapshot: GitShelfSnapshot?
    }
    private struct ShelfStepResponse: Decodable {}

    func gitShelfCapture(at root: URL) -> Result<GitShelfSnapshot, CoreCallError> {
        executeResult(command: "git.shelf", payload: ShelfRequest(root: root.standardizedFileURL.path, action: "capture", phase: nil, layer: nil, snapshot: nil))
    }

    func gitShelfPlan(at root: URL, phase: GitShelfPhase) -> Result<GitShelfPlan, CoreCallError> {
        executeResult(command: "git.shelf", payload: ShelfRequest(root: root.standardizedFileURL.path, action: "plan", phase: phase, layer: nil, snapshot: nil))
    }

    func gitShelfStep(at root: URL, phase: GitShelfPhase, layer: GitShelfLayer, snapshot: GitShelfSnapshot) -> Result<Void, CoreCallError> {
        let result: Result<ShelfStepResponse, CoreCallError> = executeResult(command: "git.shelf", payload: ShelfRequest(root: root.standardizedFileURL.path, action: phase.rawValue, phase: nil, layer: layer, snapshot: snapshot))
        return result.map { _ in () }
    }

    private struct CommitContextRequest: Encodable {
        let action: String
        let mode = "staged"
        let repositories: [GitCommitMessageRepository]
        let maximumDiffCharacters: Int?
        let token: String?
    }
    private struct CommitContextCheck: Decodable { let isCurrent: Bool }

    func gitCommitMessageCapture(_ repositories: [GitCommitMessageRepository]) -> Result<GitCommitMessageCoreCapture, CoreCallError> {
        executeResult(command: "git.commitMessageContext", payload: CommitContextRequest(action: "capture", repositories: repositories, maximumDiffCharacters: 120_000, token: nil))
    }

    func gitCommitMessageCheck(_ context: GitCommitMessageContext) -> Result<Bool, CoreCallError> {
        let result: Result<CommitContextCheck, CoreCallError> = executeResult(command: "git.commitMessageContext", payload: CommitContextRequest(action: "check", repositories: context.repositories, maximumDiffCharacters: nil, token: context.token))
        return result.map(\.isCurrent)
    }

    private struct PatchExportRequest: Encodable {
        let root: String
        let source: GitPatchSource
        let paths: [String]
        let baseRevision: String?
        let targetRevision: String?
        let metadataOnly: Bool
    }

    private struct PatchApplyRequest: Encodable {
        let root: String
        let patch: String
        let target: GitPatchTarget
        let expectedState: String?
        var metadataOnly: Bool = false
    }

    func gitPatchExport(at root: URL, source: GitPatchSource, paths: [String], base: String?, target: String?, metadataOnly: Bool) -> Result<GitPatchExport, CoreCallError> {
        executeResult(command: "git.patchExport", payload: PatchExportRequest(
            root: root.standardizedFileURL.path, source: source, paths: paths, baseRevision: base, targetRevision: target, metadataOnly: metadataOnly
        ))
    }

    func gitPatchPreview(at root: URL, patch: String, target: GitPatchTarget, metadataOnly: Bool = false) -> Result<GitPatchPreview, CoreCallError> {
        executeResult(command: "git.patchPreview", payload: PatchApplyRequest(
            root: root.standardizedFileURL.path, patch: patch, target: target, expectedState: nil, metadataOnly: metadataOnly
        ))
    }

    func gitPatchApply(at root: URL, patch: String, target: GitPatchTarget, expectedState: String) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(command: "git.patchApply", payload: PatchApplyRequest(
            root: root.standardizedFileURL.path, patch: patch, target: target, expectedState: expectedState
        ))
    }
}
