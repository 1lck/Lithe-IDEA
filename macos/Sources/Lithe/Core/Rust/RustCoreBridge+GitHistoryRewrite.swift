import Foundation
import LitheGitModule

extension RustCoreBridge {
    private struct HistoryRewritePreviewRequest: Encodable {
        let root: String
        let operation: GitHistoryRewriteOperation
        let revisions: [String]
    }

    private struct HistoryRewriteRequest: Encodable {
        let root: String
        let operation: GitHistoryRewriteOperation
        let revision: String?
        let revisions: [String]
        let message: String?
        let expectedState: GitHistoryRewriteExpectedState
    }

    func gitHistoryRewritePreview(
        at root: URL,
        operation: GitHistoryRewriteOperation,
        revisions: [String]
    ) -> Result<GitHistoryRewritePreview, CoreCallError> {
        executeResult(
            command: "git.historyRewritePreview",
            payload: HistoryRewritePreviewRequest(root: root.standardizedFileURL.path, operation: operation, revisions: revisions)
        )
    }

    func gitHistoryRewrite(
        at root: URL,
        expectedState: GitHistoryRewriteExpectedState,
        message: String?
    ) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(
            command: "git.write",
            payload: HistoryRewriteRequest(
                root: root.standardizedFileURL.path,
                operation: expectedState.operation,
                revision: expectedState.revisions.first,
                revisions: expectedState.revisions,
                message: message,
                expectedState: expectedState
            )
        )
    }
}
