import Foundation

extension RustCoreBridge {
    private struct EditorLineEditRequest: Encodable {
        let operation: String
        let source: String
        let selectionStart: Int
        let selectionLength: Int
        let commentToken: String?
    }

    private struct EditorLineEditOutcome: Decodable {
        let applied: Bool
        let text: String?
        let replacedStart: Int?
        let replacedLength: Int?
        let selectionStart: Int?
        let selectionLength: Int?
    }

    private struct EditorLineCommentTokenRequest: Encodable {
        let identifier: String
    }

    private struct EditorLineCommentTokenOutcome: Decodable {
        let token: String?
    }

    /// Applies one deterministic line-level transform; nil marks a no-op.
    func editorLineEdit(
        _ operation: EditorLineEditOperation,
        source: String,
        selection: NSRange
    ) -> EditorLineEditResult? {
        let wireOperation: String
        let commentToken: String?
        switch operation {
        case .toggleLineComment(let token):
            wireOperation = "toggleLineComment"
            commentToken = token
        case .duplicateLine:
            wireOperation = "duplicateLine"
            commentToken = nil
        case .deleteLine:
            wireOperation = "deleteLine"
            commentToken = nil
        case .moveLineUp:
            wireOperation = "moveLineUp"
            commentToken = nil
        case .moveLineDown:
            wireOperation = "moveLineDown"
            commentToken = nil
        case .copyLineUp:
            wireOperation = "copyLineUp"
            commentToken = nil
        case .copyLineDown:
            wireOperation = "copyLineDown"
            commentToken = nil
        }
        let call: Result<EditorLineEditOutcome, CoreCallError> = executeResult(
            command: "editor.lineEdit",
            payload: EditorLineEditRequest(
                operation: wireOperation,
                source: source,
                selectionStart: selection.location,
                selectionLength: selection.length,
                commentToken: commentToken
            )
        )
        guard case .success(let outcome) = call, outcome.applied,
           let text = outcome.text,
           let replacedStart = outcome.replacedStart,
           let replacedLength = outcome.replacedLength,
           let selectionStart = outcome.selectionStart,
           let selectionLength = outcome.selectionLength else {
            return nil
        }
        return EditorLineEditResult(
            text: text,
            replacedRange: NSRange(location: replacedStart, length: replacedLength),
            selection: NSRange(location: selectionStart, length: selectionLength)
        )
    }

    /// Resolves the line comment token; nil for file types without one.
    func editorLineCommentToken(forIdentifier identifier: String) -> String? {
        let call: Result<EditorLineCommentTokenOutcome, CoreCallError> = executeResult(
            command: "editor.lineCommentToken",
            payload: EditorLineCommentTokenRequest(identifier: identifier)
        )
        guard case .success(let outcome) = call else { return nil }
        return outcome.token
    }
}
