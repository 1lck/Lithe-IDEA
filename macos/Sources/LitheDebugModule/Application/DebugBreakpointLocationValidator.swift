import Foundation

/// Performs a conservative, language-aware preflight before a source
/// breakpoint is sent to a debug adapter. The adapter remains authoritative;
/// this only prevents obviously non-executable Java gutter locations.
public enum DebugBreakpointLocationValidator {
    public static func isExecutableJavaLine(source: String, line: Int) -> Bool {
        guard line > 0 else { return false }
        let lines = source.components(separatedBy: .newlines)
        guard line <= lines.count else { return false }

        var inBlockComment = false
        for (index, rawLine) in lines.enumerated() {
            let code = codeWithoutJavaCommentsAndStrings(
                rawLine,
                inBlockComment: &inBlockComment
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard index + 1 == line else { continue }
            guard !code.isEmpty,
                  !code.hasPrefix("@"),
                  !Self.nonExecutableOnlyLines.contains(code) else { return false }
            return code.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        return false
    }

    private static let nonExecutableOnlyLines: Set<String> = [
        "{", "}", "(", ")", "[", "]", ";", ",", ":"
    ]

    private static func codeWithoutJavaCommentsAndStrings(
        _ line: String,
        inBlockComment: inout Bool
    ) -> String {
        var result = ""
        var index = line.startIndex
        var inString: Character?
        while index < line.endIndex {
            let next = line.index(after: index)
            let character = line[index]
            let following = next < line.endIndex ? line[next] : nil
            if inBlockComment {
                if character == "*", following == "/" {
                    inBlockComment = false
                    index = line.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if let quote = inString {
                if character == "\\" {
                    index = next < line.endIndex ? line.index(after: next) : next
                } else if character == quote {
                    inString = nil
                    result.append(" ")
                    index = next
                } else {
                    index = next
                }
                continue
            }
            if character == "/", following == "*" {
                inBlockComment = true
                index = line.index(after: next)
            } else if character == "/", following == "/" {
                break
            } else if character == "\"" || character == "'" {
                inString = character
                result.append(" ")
                index = next
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }
}
