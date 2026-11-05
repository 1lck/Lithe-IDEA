import Foundation
import LitheModuleAPI

/// Parsing and document-range convergence for the Go to Line input. The
/// input is 1-based text — "120" or "120:35" — and the parsed result is the
/// internal 0-based line and column. The 1-based → 0-based conversion happens
/// only here; the status bar adds 1 back for display, avoiding split offsets.
struct GoToLineInput: Equatable, Sendable {
    private static let inputTransportByteLimit = 128
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

    /// Core owns the shared parsing rules. Call away from the main actor while typing.
    static func parse(_ text: String, logSink: (any LogSink)? = nil) -> GoToLineInput? {
        // Keep oversized pasted input out of the native JSON boundary.
        guard text.utf8.prefix(inputTransportByteLimit + 1).count <= inputTransportByteLimit else { return nil }
        struct Request: Encodable { let text: String }
        struct Response: Decodable {
            struct Target: Decodable { let line: Int; let column: Int; let selectsWholeLine: Bool }
            let target: Target?
        }
        let result: Result<Response, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "editor.parseNavigationInput", payload: Request(text: text))
        let target: Response.Target?
        switch result {
        case .success(let response):
            target = response.target
        case .failure(let error):
            logSink?.emit(AppCoreFallbackSelected(error: LogFailure(domain: "RustCore", code: error.code), stage: "editor.parseNavigationInput"))
            return nil
        }
        guard let target else { return nil }
        return GoToLineInput(line: target.line, column: target.column, hasExplicitColumn: !target.selectsWholeLine)
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

}
