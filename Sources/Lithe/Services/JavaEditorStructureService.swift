import Foundation

enum JavaEditorStructureService {
    static func foldRegions(in source: String) -> [JavaFoldRegion] {
        let text = source as NSString
        var regions = importRegion(in: text).map { [$0] } ?? []
        regions.append(contentsOf: commentRegions(in: text))
        regions.append(contentsOf: braceRegions(in: text))
        return regions.sorted {
            if $0.startLine == $1.startLine { return $0.endLine > $1.endLine }
            return $0.startLine < $1.startLine
        }
    }

    private static func importRegion(in source: NSString) -> JavaFoldRegion? {
        let pattern = #"(?m)^\s*import\s+[^;]+;\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: source as String, range: NSRange(location: 0, length: source.length))
        guard matches.count >= 2, let first = matches.first, let last = matches.last else { return nil }
        let startLine = lineNumber(at: first.range.location, in: source)
        let endLine = lineNumber(at: NSMaxRange(last.range), in: source)
        let firstLine = source.lineRange(for: NSRange(location: first.range.location, length: 0))
        let lastLine = source.lineRange(for: NSRange(location: max(last.range.location, NSMaxRange(last.range) - 1), length: 0))
        let hiddenStart = NSMaxRange(firstLine)
        let hiddenEnd = NSMaxRange(lastLine)
        guard hiddenEnd > hiddenStart else { return nil }
        return JavaFoldRegion(
            kind: .imports,
            startLine: startLine,
            endLine: endLine,
            hiddenRange: NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart)
        )
    }

    private static func commentRegions(in source: NSString) -> [JavaFoldRegion] {
        guard let expression = try? NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#) else { return [] }
        return expression.matches(in: source as String, range: NSRange(location: 0, length: source.length)).compactMap {
            let startLine = lineNumber(at: $0.range.location, in: source)
            let endLine = lineNumber(at: NSMaxRange($0.range), in: source)
            guard endLine > startLine else { return nil }
            let firstLine = source.lineRange(for: NSRange(location: $0.range.location, length: 0))
            let hiddenStart = NSMaxRange(firstLine)
            let hiddenEnd = NSMaxRange($0.range)
            guard hiddenEnd > hiddenStart else { return nil }
            return JavaFoldRegion(
                kind: .comment,
                startLine: startLine,
                endLine: endLine,
                hiddenRange: NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart)
            )
        }
    }

    private static func braceRegions(in source: NSString) -> [JavaFoldRegion] {
        var stack: [Int] = []
        var regions: [JavaFoldRegion] = []
        var index = 0
        var state = ScanState.code
        while index < source.length {
            let character = source.character(at: index)
            let next = index + 1 < source.length ? source.character(at: index + 1) : 0
            switch state {
            case .code:
                if character == 34 { state = .string }
                else if character == 39 { state = .character }
                else if character == 47, next == 47 { state = .lineComment; index += 1 }
                else if character == 47, next == 42 { state = .blockComment; index += 1 }
                else if character == 123 { stack.append(index) }
                else if character == 125, let opening = stack.popLast() {
                    let startLine = lineNumber(at: opening, in: source)
                    let endLine = lineNumber(at: index, in: source)
                    guard endLine > startLine else { break }
                    let openingLine = source.lineRange(for: NSRange(location: opening, length: 0))
                    let closingLine = source.lineRange(for: NSRange(location: index, length: 0))
                    let hiddenStart = NSMaxRange(openingLine)
                    let hiddenEnd = closingLine.location
                    guard hiddenEnd > hiddenStart else { break }
                    let prefix = source.substring(with: NSRange(location: openingLine.location, length: opening - openingLine.location))
                    regions.append(JavaFoldRegion(
                        kind: classify(prefix),
                        startLine: startLine,
                        endLine: endLine,
                        hiddenRange: NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart)
                    ))
                }
            case .string:
                if character == 92 { index += 1 }
                else if character == 34 { state = .code }
            case .character:
                if character == 92 { index += 1 }
                else if character == 39 { state = .code }
            case .lineComment:
                if character == 10 { state = .code }
            case .blockComment:
                if character == 42, next == 47 { state = .code; index += 1 }
            }
            index += 1
        }
        return regions
    }

    private static func classify(_ prefix: String) -> JavaFoldKind {
        if prefix.range(of: #"\b(class|interface|enum|record)\b"#, options: .regularExpression) != nil {
            return .type
        }
        if prefix.contains("(") && prefix.contains(")") { return .method }
        return .block
    }

    private static func lineNumber(at location: Int, in source: NSString) -> Int {
        guard location > 0 else { return 0 }
        var result = 0
        for index in 0..<min(location, source.length) where source.character(at: index) == 10 {
            result += 1
        }
        return result
    }

    private enum ScanState {
        case code
        case string
        case character
        case lineComment
        case blockComment
    }
}
