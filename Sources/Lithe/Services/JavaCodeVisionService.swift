import Foundation

enum JavaCodeVisionService {
    private struct Declaration: Sendable {
        let line: Int
        let utf16Column: Int
        let symbol: String
    }

    static func hints(
        for fileURL: URL,
        projectFiles: [URL],
        blameLines: [GitBlameLine]
    ) async -> [JavaCodeVisionHint] {
        await Task.detached(priority: .utility) {
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            let declarations = declarations(in: source)
            guard !declarations.isEmpty else { return [] }

            let javaSources = projectFiles
                .filter { $0.pathExtension.lowercased() == "java" }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            let blameByLine = Dictionary(uniqueKeysWithValues: blameLines.map { ($0.line, $0) })

            return declarations.map { declaration in
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: declaration.symbol))\\b"
                let usageCount = javaSources.reduce(0) { count, candidate in
                    let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                    let matches = (try? NSRegularExpression(pattern: pattern))?
                        .numberOfMatches(in: candidate, range: range) ?? 0
                    return count + matches
                }
                return JavaCodeVisionHint(
                    line: declaration.line,
                    utf16Column: declaration.utf16Column,
                    symbol: declaration.symbol,
                    usageCount: max(0, usageCount - 1),
                    implementationCount: 0,
                    authorName: blameByLine[declaration.line]?.authorName
                )
            }
        }.value
    }

    private static func declarations(in source: String) -> [Declaration] {
        let typePattern = #"\b(?:class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#
        let methodPattern = #"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^;{}]*\)\s*(?:throws\s+[^{]+)?\{"#
        let ignored = Set(["if", "for", "while", "switch", "catch", "try", "synchronized", "new"])
        let patterns = [typePattern, methodPattern]
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Declaration] = []

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: line, range: range),
                      let symbolRange = Range(match.range(at: 1), in: line) else { continue }
                let symbol = String(line[symbolRange])
                guard !ignored.contains(symbol) else { continue }
                let column = (line as NSString).range(of: symbol).location
                result.append(Declaration(line: lineIndex, utf16Column: column, symbol: symbol))
                break
            }
        }
        return result
    }
}
