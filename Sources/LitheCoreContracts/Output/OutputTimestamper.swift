import Foundation

/// Prefixes streamed process output with the time each line was received.
///
/// Maven and most build tools emit `[INFO]`/`[ERROR]` lines with no clock at
/// all, which makes "when did this stall" unanswerable from the log alone.
/// Spring Boot already prints its own timestamp, so those lines are left
/// untouched rather than carrying two clocks.
package enum OutputTimestamper {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Matches a leading clock in the shapes tools actually emit: bare
    /// `10:12:33`, ISO `2026-08-08T10:12:33.123`, and the space-separated
    /// variant Spring Boot uses.
    private static let leadingTimeExpression = try! NSRegularExpression(
        pattern: #"^\s*(?:\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}"#
    )

    /// - Parameter continuingLine: true when the previous chunk ended mid-line,
    ///   so this chunk's first line is a continuation and must not be stamped.
    package static func stamped(_ value: String, continuingLine: Bool, now: Date = Date()) -> String {
        guard !value.isEmpty else { return value }
        let stamp = formatter.string(from: now) + " "
        var result = ""
        var isLineStart = !continuingLine
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            if isLineStart, !line.isEmpty, !hasLeadingTime(String(line)) {
                result += stamp
            }
            result += line
            result += "\n"
            isLineStart = true
        }
        // `split` produces a trailing empty element for a chunk that ends in a
        // newline; the loop above already wrote that newline.
        result.removeLast()
        return result
    }

    package static func hasLeadingTime(_ line: String) -> Bool {
        leadingTimeLength(of: line) != nil
    }

    /// Length of the clock at the start of the line, in characters, or nil when
    /// the line does not begin with one. Callers use it to style the stamp
    /// separately from the message.
    package static func leadingTimeLength(of line: String) -> Int? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = leadingTimeExpression.firstMatch(in: line, range: range),
              let matched = Range(match.range, in: line) else { return nil }
        // Include the fractional seconds and the separating space so the whole
        // gutter recedes, not just the `HH:mm:ss` part.
        var end = matched.upperBound
        while end < line.endIndex, line[end].isNumber || line[end] == "." || line[end] == " " {
            end = line.index(after: end)
            if line[line.index(before: end)] == " " { break }
        }
        return line.distance(from: line.startIndex, to: end)
    }
}
