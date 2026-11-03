import Foundation
import LitheCoreContracts

// Value types for the host-internal document/editor service (plugin API plan
// API-09/API-10). They are deliberately free of WebKit, Monaco and SwiftUI so the
// future plugin dispatch layer can map them onto its public contract.
//
// Coordinates: lines and columns are both one-based. A column counts UTF-16 code
// units (the LSP unit), excluding the line terminator, so the valid columns of a
// line are `1...lineLength + 1`. CR, LF and CRLF each end one line. Ranges are
// half-open `[start, end)`. Monaco uses the same one-based numbers; LSP adapters
// subtract one from both line and column at their own boundary.

/// Explicit caller context. The service never falls back to the frontmost window.
struct EditorDocumentScope: Hashable, Sendable {
    /// The `AppModel.id` of the window that owns the documents.
    let windowID: UUID
    /// The workspace root the caller was authorised for; `nil` means no workspace.
    let workspaceURL: URL?
}

struct EditorTextPosition: Hashable, Comparable, Sendable {
    /// One-based line.
    let line: Int
    /// One-based UTF-16 column.
    let column: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line ? lhs.column < rhs.column : lhs.line < rhs.line
    }
}

/// Half-open range. `start` must not be after `end`.
struct EditorTextRange: Hashable, Sendable {
    let start: EditorTextPosition
    let end: EditorTextPosition

    var isEmpty: Bool { start == end }
}

struct EditorSelection: Hashable, Sendable {
    /// Where the selection was started.
    let anchor: EditorTextPosition
    /// Where the caret is; may precede `anchor` for a backwards selection.
    let active: EditorTextPosition

    var range: EditorTextRange { EditorTextRange(start: min(anchor, active), end: max(anchor, active)) }
    var isEmpty: Bool { anchor == active }
    var isReversed: Bool { active < anchor }
}

/// Selections captured at one document version.
struct EditorSelectionsSnapshot: Hashable, Sendable {
    let documentID: UUID
    let version: UInt64
    /// Sorted by range start, then range end. Empty when no editor view has ever
    /// shown the document.
    let selections: [EditorSelection]
    /// Index into `selections` of the editor's primary caret.
    let primaryIndex: Int?
}

enum EditorLineEnding: String, Hashable, Sendable {
    case lf, crlf, cr
    /// More than one terminator style. Inserted line breaks use the first one.
    case mixed

    var separator: String? {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        case .mixed: nil
        }
    }
}

/// Metadata of an open document. `version` is the document owner's content
/// version (see `EditorDocument.contentVersion`).
struct EditorDocumentSummary: Hashable, Sendable {
    let documentID: UUID
    let version: UInt64
    /// `/`-separated path relative to the scope's workspace, or `nil` outside it.
    let workspaceRelativePath: String?
    let languageID: String?
    let isReadOnly: Bool
    let isDirty: Bool
    /// Codec the in-memory text was decoded with.
    let encoding: DocumentEncoding
    let lineEnding: EditorLineEnding
}

/// Full live buffer, including unsaved edits; never re-read from disk.
struct EditorDocumentSnapshot: Hashable, Sendable {
    let summary: EditorDocumentSummary
    let text: String
}

struct EditorTextEdit: Hashable, Sendable {
    let range: EditorTextRange
    /// Line breaks of any style are written with the document's line ending.
    let text: String
}

struct EditorDocumentEditResult: Hashable, Sendable {
    let documentID: UUID
    /// Version immediately after this batch, before any later user input.
    let version: UInt64
    /// `false` when the batch was empty and nothing changed.
    let applied: Bool
}

enum EditorTextInvalidRangeReason: String, Hashable, Sendable {
    /// `start` is after `end`.
    case reversed
    /// An endpoint falls between the two code units of a surrogate pair.
    case splitsSurrogatePair
}

/// Stable failure classes; the dispatch layer maps them to public error codes.
enum EditorDocumentServiceError: Error, Hashable, Sendable {
    /// The scope does not name this window or its current workspace.
    case contextMismatch
    /// The document is unknown to the scope or has been closed.
    case documentNotFound
    case readOnly
    /// The caller's version is not the current one. `actual` lets callers re-read.
    case versionConflict(expected: UInt64, actual: UInt64)
    /// A position names a line or column that does not exist.
    case rangeOutOfBounds(editIndex: Int)
    case invalidRange(editIndex: Int, reason: EditorTextInvalidRangeReason)
    /// Two edits overlap. Indices refer to the caller's original order.
    case overlappingRanges(editIndex: Int, otherEditIndex: Int)
    /// An input-method composition is active; retry after it commits.
    case compositionInProgress
    /// Selection replacement needs one text, or one per selection.
    case replacementCountMismatch(selections: Int, replacements: Int)
    /// No live editor owns the buffer, or it is synchronizing/failed. Retryable.
    case editorUnavailable
}
