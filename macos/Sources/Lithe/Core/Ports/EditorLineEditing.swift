import Foundation

/// Kinds of deterministic line-level editing operations resolved by Rust Core.
enum EditorLineEditOperation: Equatable, Sendable {
    case toggleLineComment(token: String)
    case duplicateLine
    case deleteLine
    case moveLineUp
    case moveLineDown
    case copyLineUp
    case copyLineDown
}

/// Result of one line-level editing transform. `text` replaces `replacedRange`
/// in the document and `selection` is the UTF-16 range to restore afterwards.
/// All offsets are UTF-16 code units.
struct EditorLineEditResult: Equatable, Sendable {
    let text: String
    let replacedRange: NSRange
    let selection: NSRange
}

/// Deterministic line-level editing transforms backed by Rust Core. Views
/// apply the returned result through their native text engine; they never
/// implement the transforms themselves so macOS and Windows cannot drift.
protocol EditorLineEditing: Sendable {
    /// Applies one transform and returns nil when it is a legitimate no-op,
    /// such as moving the first line up.
    func lineEdit(
        _ operation: EditorLineEditOperation,
        source: String,
        selection: NSRange
    ) -> EditorLineEditResult?

    /// Resolves the line comment token for a file extension, file name
    /// (including dotfiles such as `.env`), or language id; nil for file
    /// types without a line comment token.
    func lineCommentToken(forIdentifier identifier: String) -> String?
}
