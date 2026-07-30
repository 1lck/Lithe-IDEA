import Foundation

enum JavaEditorStructureService {
    static func fallbackParameterHints(in source: String, declarationSources: [String]) -> [JavaInlayHint] {
        let declarations = declarationSources.reduce(into: [String: [[String]]]()) { result, text in
            for (name, parameters) in methodDeclarations(in: text) {
                result[name, default: []].append(parameters)
            }
        }
        let text = source as NSString
        let pattern = #"\b([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*\(([^(){};]*)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var hints: [JavaInlayHint] = []

        for match in expression.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            let argumentsRange = match.range(at: 2)
            let rawArguments = text.substring(with: argumentsRange)
            if looksLikeParameterDeclarationList(rawArguments) { continue }
            let argumentStarts = commaSeparatedItemStarts(in: text, range: argumentsRange)
            guard !argumentStarts.isEmpty,
                  let candidates = declarations[name],
                  let parameters = candidates.first(where: { $0.count == argumentStarts.count }) else { continue }

            let suffixStart = NSMaxRange(match.range)
            let suffixLength = min(40, text.length - suffixStart)
            let suffix = text.substring(with: NSRange(location: suffixStart, length: suffixLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.hasPrefix("{") || suffix.hasPrefix("throws ") { continue }

            for (index, location) in argumentStarts.enumerated() {
                let line = lineNumber(at: location, in: text)
                let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                hints.append(JavaInlayHint(
                    line: line,
                    utf16Column: location - lineRange.location,
                    label: parameters[index]
                ))
            }
        }
        return Array(Set(hints)).sorted {
            if $0.line == $1.line { return $0.utf16Column < $1.utf16Column }
            return $0.line < $1.line
        }
    }

    static func implementationMarkers(in source: String) -> [JavaImplementationMarker] {
        let text = source as NSString
        var result: [JavaImplementationMarker] = []
        let patterns: [(String, Bool)] = [
            (#"(?m)^\s*(?:public\s+)?interface\s+[A-Za-z_$][A-Za-z0-9_$]*"#, true),
            (#"(?m)^\s*(?:public\s+)?(?:[A-Za-z_$][A-Za-z0-9_$<>?,.\[\]\s]+\s+)?[A-Za-z_$][A-Za-z0-9_$]*\s*\([^;{}]*\)\s*(?:throws\s+[^;]+)?;\s*$"#, false)
        ]
        for (pattern, isType) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let line = lineNumber(at: match.range.location, in: text)
                let lineRange = text.lineRange(for: NSRange(location: match.range.location, length: 0))
                result.append(JavaImplementationMarker(
                    line: line,
                    utf16Column: max(0, match.range.location - lineRange.location),
                    isType: isType
                ))
            }
        }
        return Array(Set(result)).sorted { $0.line < $1.line }
    }

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
        let pattern = #"(?m)^[ \t]*import[ \t]+[^;]+;[ \t]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: source as String, range: NSRange(location: 0, length: source.length))
        guard matches.count >= 2, let first = matches.first, let last = matches.last else { return nil }
        let startLine = lineNumber(at: first.range.location, in: source)
        let endLine = lineNumber(at: last.range.location, in: source)
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

    private static func methodDeclarations(in source: String) -> [(String, [String])] {
        let text = source as NSString
        let pattern = #"\b([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*\(([^(){};]*)\)[ \t]*(?:throws[^{]+)?\{"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let excluded = Set(["if", "for", "while", "switch", "catch", "new"])
        return expression.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let name = text.substring(with: match.range(at: 1))
            guard !excluded.contains(name) else { return nil }
            let rawParameters = text.substring(with: match.range(at: 2))
            let parameters = rawParameters.split(separator: ",").compactMap { parameter -> String? in
                let cleaned = parameter
                    .replacingOccurrences(of: #"@[A-Za-z_$][A-Za-z0-9_$]*(?:\([^)]*\))?"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
            }
            return parameters.isEmpty ? nil : (name, parameters)
        }
    }

    private static func commaSeparatedItemStarts(in source: NSString, range: NSRange) -> [Int] {
        guard range.length > 0 else { return [] }
        var starts: [Int] = []
        var itemStart = range.location
        var index = range.location
        var depth = 0
        var quote: unichar?
        while index < NSMaxRange(range) {
            let character = source.character(at: index)
            if let activeQuote = quote {
                if character == 92 { index += 1 }
                else if character == activeQuote { quote = nil }
            } else if character == 34 || character == 39 {
                quote = character
            } else if character == 40 || character == 91 || character == 123 {
                depth += 1
            } else if character == 41 || character == 93 || character == 125 {
                depth = max(0, depth - 1)
            } else if character == 44, depth == 0 {
                if let start = firstNonWhitespace(in: source, range: NSRange(location: itemStart, length: index - itemStart)) {
                    starts.append(start)
                }
                itemStart = index + 1
            }
            index += 1
        }
        if let start = firstNonWhitespace(
            in: source,
            range: NSRange(location: itemStart, length: NSMaxRange(range) - itemStart)
        ) {
            starts.append(start)
        }
        return starts
    }

    private static func firstNonWhitespace(in source: NSString, range: NSRange) -> Int? {
        for index in range.location..<NSMaxRange(range) {
            guard let scalar = UnicodeScalar(source.character(at: index)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) else { return index }
        }
        return nil
    }

    private static func looksLikeParameterDeclarationList(_ text: String) -> Bool {
        let items = text.split(separator: ",")
        guard !items.isEmpty else { return false }
        return items.allSatisfy { item in
            let words = item.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 2, let name = words.last else { return false }
            return name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
        }
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
