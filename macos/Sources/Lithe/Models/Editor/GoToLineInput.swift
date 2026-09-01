import Foundation

/// Parsing and document-range convergence for the Go to Line input. The
/// input is 1-based text — "120" or "120:35" — and the parsed result is the
/// internal 0-based line and column. The 1-based → 0-based conversion happens
/// only here; the status bar adds 1 back for display, avoiding split offsets.
struct GoToLineInput: Equatable {
    let line: Int
    let column: Int
    /// True when the input carried an explicit ":column" part. Line-only
    /// jumps select the whole target line; column jumps place the caret at
    /// the column so the entered position is never discarded.
    let hasExplicitColumn: Bool

    init(line: Int, column: Int, hasExplicitColumn: Bool = false) {
        self.line = line
        self.column = column
        self.hasExplicitColumn = hasExplicitColumn
    }

    /// Parses "120", "120:35", or whitespace-padded equivalents. Empty input,
    /// non-numeric text, multiple colons, zero, and negative values are all
    /// invalid and yield `nil`, making the jump a no-op.
    static func parse(_ text: String) -> GoToLineInput? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard let line = oneBasedNumber(in: parts[0]) else { return nil }
        let hasExplicitColumn = parts.count == 2
        guard let column = hasExplicitColumn ? oneBasedNumber(in: parts[1]) : 1 else {
            return nil
        }
        return GoToLineInput(line: line - 1, column: column - 1, hasExplicitColumn: hasExplicitColumn)
    }

    /// Converges 0-based line and column into the given document content:
    /// an out-of-range line collapses to the last line, an out-of-range
    /// column to the end of that line's content (excluding its terminator),
    /// negatives to the origin. An empty document only ever addresses the
    /// document start. Lines break on LF, CRLF, and CR — the same
    /// terminators the editor's `TextLineIndex` recognizes — and a trailing
    /// terminator yields a final empty line. Callers must re-converge with
    /// the live document text right before jumping; line counts are never
    /// cached.
    static func clamped(
        line: Int,
        column: Int,
        hasExplicitColumn: Bool = false,
        in content: String
    ) -> GoToLineInput {
        let text = content as NSString
        let length = text.length
        let requestedLine = max(line, 0)
        var lineIndex = 0
        var lineStart = 0
        while true {
            var scan = lineStart
            var terminatorLength = 0
            while scan < length {
                let character = text.character(at: scan)
                if character == 10 {
                    terminatorLength = 1
                    break
                }
                if character == 13 {
                    terminatorLength = (scan + 1 < length && text.character(at: scan + 1) == 10) ? 2 : 1
                    break
                }
                scan += 1
            }
            if lineIndex == requestedLine || scan == length {
                // Hit the requested line, or ran past the last content line
                // and converge onto this final line.
                return GoToLineInput(
                    line: lineIndex,
                    column: min(max(column, 0), scan - lineStart),
                    hasExplicitColumn: hasExplicitColumn
                )
            }
            lineIndex += 1
            lineStart = scan + terminatorLength
        }
    }

    private static func oneBasedNumber(in part: Substring) -> Int? {
        guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 1 else {
            return nil
        }
        return value
    }
}
