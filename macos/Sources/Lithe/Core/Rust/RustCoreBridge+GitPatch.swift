import Foundation
import LitheGitModule

extension RustCoreBridge {
    private struct PatchExportRequest: Encodable {
        let root: String
        let source: GitPatchSource
        let paths: [String]
        let baseRevision: String?
        let targetRevision: String?
    }

    private struct PatchApplyRequest: Encodable {
        let root: String
        let patch: String
        let target: GitPatchTarget
        let expectedState: String?
    }

    func gitPatchExport(at root: URL, source: GitPatchSource, paths: [String], base: String?, target: String?) -> Result<GitPatchExport, CoreCallError> {
        executeResult(command: "git.patchExport", payload: PatchExportRequest(
            root: root.standardizedFileURL.path, source: source, paths: paths, baseRevision: base, targetRevision: target
        ))
    }

    func gitPatchPreview(at root: URL, patch: String, target: GitPatchTarget) -> Result<GitPatchPreview, CoreCallError> {
        executeResult(command: "git.patchPreview", payload: PatchApplyRequest(
            root: root.standardizedFileURL.path, patch: patch, target: target, expectedState: nil
        ))
    }

    func gitPatchApply(at root: URL, patch: String, target: GitPatchTarget, expectedState: String) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(command: "git.patchApply", payload: PatchApplyRequest(
            root: root.standardizedFileURL.path, patch: patch, target: target, expectedState: expectedState
        ))
    }
}
