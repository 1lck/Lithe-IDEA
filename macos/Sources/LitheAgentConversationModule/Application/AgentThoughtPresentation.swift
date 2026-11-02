import Foundation

/// A reasoning summary is a sequence of activity headings and Markdown bodies,
/// not one ordinary reply. Source text and upstream message identities stay intact.
public enum AgentThoughtPresentation {
    public struct Section: Equatable, Sendable {
        public let title: String?
        public let body: String
        public let isTitleComplete: Bool
    }

    public static func sections(_ source: String, isStreaming: Bool = false, usesSummaryHeadings: Bool = true) -> [Section] {
        guard usesSummaryHeadings else {
            return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? []
                : [Section(title: nil, body: source, isTitleComplete: true)]
        }
        var result: [Section] = []
        var title: String?
        var body = ""
        var complete = true
        var fence: (marker: Character, count: Int)?
        let lines = source.components(separatedBy: "\n")
        func flush() {
            let content = body.trimmingCharacters(in: .newlines)
            if title != nil || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Section(title: title, body: content, isTitleComplete: complete))
            }
            title = nil
            body = ""
            complete = true
        }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            var fenceLine = false
            if !indented, let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 {
                    fenceLine = true
                    if let current = fence {
                        if current.marker == marker, count >= current.count,
                           trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (marker, count) }
                }
            }
            // A heading starts a summary paragraph, or immediately follows another
            // heading. Bold within ordinary prose, code and links stays Markdown.
            let paragraphStart = index == 0 || lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var remainder = line
            let syntax = CharacterSet(charactersIn: "*`\\[]<>_&")
            if !indented, !fenceLine, fence == nil, paragraphStart {
                var candidate = trimmed
                while candidate.hasPrefix("**") {
                    let afterOpen = String(candidate.dropFirst(2))
                    let close = afterOpen.range(of: "**")
                    let draft = isStreaming && index == lines.count - 1 && close == nil
                    // A network chunk may stop inside the closing delimiter.
                    let heading = close.map { String(afterOpen[..<$0.lowerBound]) }
                        ?? (draft && afterOpen.hasSuffix("*") ? String(afterOpen.dropLast()) : afterOpen)
                    if draft && heading.isEmpty { remainder = ""; break }
                    guard !heading.isEmpty, heading == heading.trimmingCharacters(in: .whitespaces),
                          heading.rangeOfCharacter(from: syntax) == nil,
                          close != nil || draft else { break }
                    flush()
                    title = heading
                    complete = close != nil
                    candidate = close.map { String(afterOpen[$0.upperBound...]) } ?? ""
                    remainder = candidate.trimmingCharacters(in: .whitespaces)
                    if isStreaming, index == lines.count - 1, candidate == "*" { remainder = "" }
                }
            }
            body += remainder
            if index < lines.count - 1 { body += "\n" }
        }
        flush()
        return result
    }

    /// An unfinished title must not replace the last completed activity heading.
    public static func currentTitle(_ source: String) -> String? {
        sections(source, isStreaming: true).last { $0.title != nil && $0.isTitleComplete }?.title
    }
}
