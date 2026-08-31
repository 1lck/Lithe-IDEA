import Foundation

/// Extracts source-referenced Java expressions for automatic debugger
/// inspection. The projection is intentionally deterministic and bounded so
/// selecting a stack frame cannot trigger an unbounded batch of evaluations.
enum DebugAutomaticExpressionProjection {
    static let maximumExpressions = 8

    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch",
        "char", "class", "const", "continue", "default", "do", "double",
        "else", "enum", "extends", "false", "final", "finally", "float",
        "for", "goto", "if", "implements", "import", "instanceof", "int",
        "interface", "long", "native", "new", "null", "package", "private",
        "protected", "public", "record", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws", "transient",
        "true", "try", "var", "void", "volatile", "while", "yield"
    ]

    static func javaExpressions(forLine line: Int, in source: NSString) -> [String] {
        guard let lineRange = lineRange(for: line, in: source) else { return [] }
        let lineSource = source.substring(with: lineRange) as NSString
        var values: [String] = []
        var known = Set<String>()
        var location = 0
        while location < lineSource.length, values.count < maximumExpressions {
            guard isIdentifierStart(at: location, in: lineSource) else {
                location += 1
                continue
            }
            let start = location
            location += 1
            while location < lineSource.length,
                  isIdentifierCharacter(at: location, in: lineSource) {
                location += 1
            }
            let range = NSRange(location: start, length: location - start)
            let token = lineSource.substring(with: range)
            let previous = previousNonWhitespaceCharacter(before: start, in: lineSource)
            let next = nextNonWhitespaceCharacter(after: location, in: lineSource)
            guard !javaKeywords.contains(token), previous != ".", next != "(" else { continue }
            if known.insert(token).inserted { values.append(token) }
        }
        return values
    }

    private static func isIdentifierStart(at location: Int, in source: NSString) -> Bool {
        guard let scalar = scalar(at: location, in: source) else { return false }
        return CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
            .contains(scalar)
    }

    private static func isIdentifierCharacter(at location: Int, in source: NSString) -> Bool {
        guard let scalar = scalar(at: location, in: source) else { return false }
        return CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
            .contains(scalar)
    }

    private static func scalar(at location: Int, in source: NSString) -> UnicodeScalar? {
        guard location >= 0, location < source.length else { return nil }
        return UnicodeScalar(source.character(at: location))
    }

    private static func previousNonWhitespaceCharacter(
        before location: Int,
        in source: NSString
    ) -> Character? {
        var cursor = location - 1
        while cursor >= 0 {
            guard let scalar = scalar(at: cursor, in: source) else { return nil }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return Character(scalar) }
            cursor -= 1
        }
        return nil
    }

    private static func nextNonWhitespaceCharacter(
        after location: Int,
        in source: NSString
    ) -> Character? {
        var cursor = location
        while cursor < source.length {
            guard let scalar = scalar(at: cursor, in: source) else { return nil }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return Character(scalar) }
            cursor += 1
        }
        return nil
    }

    private static func lineRange(for line: Int, in source: NSString) -> NSRange? {
        guard line >= 0, source.length > 0 else { return nil }
        var location = 0
        var currentLine = 0
        while currentLine < line, location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(range)
            guard next > location else { return nil }
            location = next
            currentLine += 1
        }
        guard currentLine == line, location < source.length else { return nil }
        return source.lineRange(for: NSRange(location: location, length: 0))
    }
}
