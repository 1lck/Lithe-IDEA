import Foundation

/// Editor selection computation for a Go to Line navigation target.
/// Line-only targets select the whole target line's content with the line
/// terminator excluded (LF, CRLF, or CR); column targets place a zero-length
/// caret at the converged column so an explicitly entered column is never
/// discarded. Line breaks follow the same LF/CRLF/CR rules as
/// `TextLineIndex` and `GoToLineInput.clamped`, keeping jump targets,
/// gutter numbering, and the status bar caret on one line-index definition.
enum GoToLineSelection {
    static func targetRange(
        line: Int,
        utf16Column: Int,
        selectsWholeLine: Bool,
        in text: NSString
    ) -> NSRange {
        let length = text.length
        let requestedLine = max(line, 0)
        var lineIndex = 0
        var lineStart = 0
        var contentEnd = 0
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
            contentEnd = scan
            if lineIndex == requestedLine || scan == length {
                // Hit the requested line, or converge onto the final line.
                break
            }
            lineIndex += 1
            lineStart = scan + terminatorLength
        }
        if selectsWholeLine {
            return NSRange(location: lineStart, length: contentEnd - lineStart)
        }
        let location = min(contentEnd, lineStart + max(utf16Column, 0))
        return NSRange(location: location, length: 0)
    }
}
