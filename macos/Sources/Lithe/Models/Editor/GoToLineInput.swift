import Foundation

/// Parsing and document-range convergence for the Go to Line input. The
/// input is 1-based text — "120" or "120:35" — and the parsed result is the
/// internal 0-based line and column. The 1-based → 0-based conversion happens
/// only here; the status bar adds 1 back for display, avoiding split offsets.
struct GoToLineInput: Equatable {
    let line: Int
    let column: Int

    /// Parses "120", "120:35", or whitespace-padded equivalents. Empty input,
    /// non-numeric text, multiple colons, zero, and negative values are all
    /// invalid and yield `nil`, making the jump a no-op.
    static func parse(_ text: String) -> GoToLineInput? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard let line = oneBasedNumber(in: parts[0]) else { return nil }
        let column = parts.count == 2 ? oneBasedNumber(in: parts[1]) : 1
        guard let column else { return nil }
        return GoToLineInput(line: line - 1, column: column - 1)
    }

    /// Converges 0-based line and column into the given document content:
    /// an out-of-range line collapses to the last line, an out-of-range
    /// column to the end of that line (counted in UTF-16 units to match
    /// `EditorCaret.utf16Column`), negatives to the origin. An empty document
    /// only ever addresses the document start. Callers must re-converge with
    /// the live document text right before jumping; line counts are never
    /// cached.
    static func clamped(line: Int, column: Int, in content: String) -> GoToLineInput {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let clampedLine = min(max(line, 0), lines.count - 1)
        let lineLength = lines[clampedLine].utf16.count
        return GoToLineInput(line: clampedLine, column: min(max(column, 0), lineLength))
    }

    private static func oneBasedNumber(in part: Substring) -> Int? {
        guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 1 else {
            return nil
        }
        return value
    }
}
