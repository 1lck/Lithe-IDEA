import Foundation

/// Line table of a text in UTF-16 code units. CR, LF and CRLF each terminate one
/// line, matching Monaco's normalized model and LSP.
struct EditorTextLineIndex: Sendable {
    let units: [UInt16]
    /// UTF-16 offset of the first unit of each line.
    private(set) var lineStarts: [Int] = [0]
    /// UTF-16 offset just before each line's terminator (or the text end).
    private(set) var contentEnds: [Int] = []
    let lineEnding: EditorLineEnding
    /// Separator written for inserted line breaks: the first one in the text, LF when none.
    let insertionSeparator: String

    init(_ text: String) {
        units = Array(text.utf16)
        var seen: Set<String> = []
        var first: String?
        var index = 0
        while index < units.count {
            let unit = units[index]
            guard unit == 13 || unit == 10 else { index += 1; continue }
            contentEnds.append(index)
            let separator: String
            if unit == 13, index + 1 < units.count, units[index + 1] == 10 {
                separator = "\r\n"; index += 2
            } else {
                separator = unit == 13 ? "\r" : "\n"; index += 1
            }
            if first == nil { first = separator }
            seen.insert(separator)
            lineStarts.append(index)
        }
        contentEnds.append(units.count)
        switch seen.count {
        case 0, 1:
            lineEnding = first == "\r\n" ? .crlf : first == "\r" ? .cr : .lf
        default:
            lineEnding = .mixed
        }
        insertionSeparator = first ?? "\n"
    }

    var lineCount: Int { lineStarts.count }

    /// UTF-16 offset of a one-based position, or `nil` when it does not exist.
    func offset(of position: EditorTextPosition) -> Int? {
        guard position.line >= 1, position.line <= lineCount, position.column >= 1 else { return nil }
        let start = lineStarts[position.line - 1]
        let offset = start + position.column - 1
        return offset <= contentEnds[position.line - 1] ? offset : nil
    }

    /// One-based position of a UTF-16 offset that is not inside a CRLF pair.
    func position(at offset: Int) -> EditorTextPosition {
        let clamped = min(max(offset, 0), units.count)
        // Last line start not after the offset.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        let column = min(clamped, contentEnds[low]) - lineStarts[low] + 1
        return EditorTextPosition(line: low + 1, column: column)
    }

    /// True when `offset` lies between a high and a low surrogate.
    func splitsSurrogatePair(at offset: Int) -> Bool {
        guard offset > 0, offset < units.count else { return false }
        return UTF16.isLeadSurrogate(units[offset - 1]) && UTF16.isTrailSurrogate(units[offset])
    }
}

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

/// Validates a whole batch before anything is applied: every range must exist,
/// keep surrogate pairs intact and not overlap another edit. Zero-length
/// insertions at the same position are allowed and keep the caller's order.
enum EditorTextEditPlanner {
    static func plan(_ edits: [EditorTextEdit], in index: EditorTextLineIndex) throws -> [PlannedEditorTextEdit] {
        var planned: [PlannedEditorTextEdit] = []
        planned.reserveCapacity(edits.count)
        for (position, edit) in edits.enumerated() {
            guard let start = index.offset(of: edit.range.start), let end = index.offset(of: edit.range.end) else {
                throw EditorDocumentServiceError.rangeOutOfBounds(editIndex: position)
            }
            guard start <= end else {
                throw EditorDocumentServiceError.invalidRange(editIndex: position, reason: .reversed)
            }
            guard !index.splitsSurrogatePair(at: start), !index.splitsSurrogatePair(at: end) else {
                throw EditorDocumentServiceError.invalidRange(editIndex: position, reason: .splitsSurrogatePair)
            }
            let normalized = normalizeLineBreaks(edit.text, to: "\n")
            planned.append(PlannedEditorTextEdit(
                index: position, range: edit.range, utf16Offset: start, utf16Length: end - start,
                text: index.insertionSeparator == "\n" ? normalized
                    : normalized.replacingOccurrences(of: "\n", with: index.insertionSeparator),
                normalizedText: normalized))
        }
        // Stable order: by start, then end, then the caller's order.
        planned.sort {
            ($0.utf16Offset, $0.utf16Offset + $0.utf16Length, $0.index)
                < ($1.utf16Offset, $1.utf16Offset + $1.utf16Length, $1.index)
        }
        for (previous, next) in zip(planned, planned.dropFirst())
        where next.utf16Offset < previous.utf16Offset + previous.utf16Length {
            throw EditorDocumentServiceError.overlappingRanges(
                editIndex: min(previous.index, next.index), otherEditIndex: max(previous.index, next.index))
        }
        return planned
    }

    /// Applies a validated plan to the text it was planned against.
    static func apply(_ plan: [PlannedEditorTextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.utf16Offset, length: edit.utf16Length), with: edit.text)
        }
        return result as String
    }

    static func normalizeLineBreaks(_ text: String, to separator: String) -> String {
        guard text.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf16.count)
        // Swift treats CRLF as one Character, so each Character is one line break.
        for character in text {
            if character == "\r\n" || character == "\r" || character == "\n" { result += separator }
            else { result.append(character) }
        }
        return result
    }
}
