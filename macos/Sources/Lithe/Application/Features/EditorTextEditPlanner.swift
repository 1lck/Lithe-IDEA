import Foundation

/// One validated edit in UTF-16 offsets of the source text.
struct PlannedEditorTextEdit: Hashable, Sendable {
    /// Position of the edit in the caller's batch.
    let index: Int
    let range: EditorTextRange
    let utf16Offset: Int
    let utf16Length: Int
    /// Replacement with line breaks written in the document's insertion separator.
    let text: String
    /// Replacement with LF line breaks, as Monaco's normalized model expects.
    let normalizedText: String
}

/// A batch validated against one exact text, in stable application order.
struct EditorTextEditPlan: Hashable, Sendable {
    let lineEnding: EditorLineEnding
    /// Separator for inserted line breaks: the text's first one, LF when none.
    let lineSeparator: String
    let edits: [PlannedEditorTextEdit]
}

/// Plugin document edits are planned by Rust Core (`editor.planTextEdits`),
/// which shares its line index, ordering and overlap rules with
/// `lsp.applyTextEdits`. Every range must exist, keep surrogate pairs intact
/// and not overlap another edit; zero-length insertions at the same position
/// keep the caller's order. The host keeps versions, undo and the surface.
enum EditorTextEditPlanner {
    private struct WirePosition: Codable { let line: Int; let column: Int }
    private struct WireRange: Encodable { let start: WirePosition; let end: WirePosition }
    private struct WireEdit: Encodable { let range: WireRange; let text: String }
    private struct Request: Encodable {
        let text: String
        let edits: [WireEdit]
        let positions: [WirePosition]
    }
    private struct Response: Decodable {
        struct Edit: Decodable {
            let index: Int
            let utf16Offset: Int
            let utf16Length: Int
            let text: String
            let normalizedText: String
        }
        struct Rejection: Decodable {
            let reason: String
            let editIndex: Int?
            let otherEditIndex: Int?
            let positionIndex: Int?
        }
        let lineEnding: String
        let lineSeparator: String
        let edits: [Edit]
        let rejection: Rejection?
    }

    /// Plans `edits` against `text`. `positions` must also exist in `text`
    /// (for example reported selection endpoints); a missing one fails with
    /// `editorUnavailable`, because it means the editor and its mirror diverged.
    /// Copies the whole text across the Core boundary; call away from the main
    /// actor for large batches.
    nonisolated static func plan(
        _ edits: [EditorTextEdit],
        in text: String,
        positions: [EditorTextPosition] = []
    ) throws -> EditorTextEditPlan {
        func wire(_ position: EditorTextPosition) -> WirePosition {
            // Core reads one-based unsigned values; zero is rejected there as out of bounds.
            WirePosition(line: max(position.line, 0), column: max(position.column, 0))
        }
        let request = Request(
            text: text,
            edits: edits.map { WireEdit(range: WireRange(start: wire($0.range.start), end: wire($0.range.end)), text: $0.text) },
            positions: positions.map(wire))
        let result: Result<Response, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "editor.planTextEdits", payload: request)
        guard case .success(let response) = result,
              let lineEnding = EditorLineEnding(rawValue: response.lineEnding) else {
            throw EditorDocumentServiceError.editorUnavailable
        }
        if let rejection = response.rejection {
            throw error(for: rejection)
        }
        return EditorTextEditPlan(
            lineEnding: lineEnding,
            lineSeparator: response.lineSeparator,
            edits: try response.edits.map { edit in
                guard edits.indices.contains(edit.index) else { throw EditorDocumentServiceError.editorUnavailable }
                return PlannedEditorTextEdit(
                    index: edit.index, range: edits[edit.index].range, utf16Offset: edit.utf16Offset,
                    utf16Length: edit.utf16Length, text: edit.text, normalizedText: edit.normalizedText)
            })
    }

    private nonisolated static func error(for rejection: Response.Rejection) -> EditorDocumentServiceError {
        guard let index = rejection.editIndex else { return .editorUnavailable }
        switch rejection.reason {
        case "rangeOutOfBounds": return .rangeOutOfBounds(editIndex: index)
        case "reversed": return .invalidRange(editIndex: index, reason: .reversed)
        case "splitsSurrogatePair": return .invalidRange(editIndex: index, reason: .splitsSurrogatePair)
        case "overlappingRanges":
            return .overlappingRanges(editIndex: index, otherEditIndex: rejection.otherEditIndex ?? index)
        default: return .editorUnavailable
        }
    }

    /// Applies a validated plan to the text it was planned against.
    static func apply(_ plan: [PlannedEditorTextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.utf16Offset, length: edit.utf16Length), with: edit.text)
        }
        return result as String
    }
}
