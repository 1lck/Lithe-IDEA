import Foundation

/// Fast, language-neutral navigation candidates backed by the workspace text index.
///
/// These locations are lexical candidates rather than semantic truth. The session
/// manager may surface them while an LSP request is in flight, then replace them
/// with the authoritative server response.
@MainActor
final class ProjectSymbolFeatureProvider: LanguageFeatureProvider {
    let id = "project-symbols"
    let priority: LanguageFeatureProviderPriority = .projectSymbols

    private let operations: any WorkspaceOperations
    private let visibilityRules: () -> FileVisibilityRules

    init(
        operations: any WorkspaceOperations,
        visibilityRules: @escaping () -> FileVisibilityRules
    ) {
        self.operations = operations
        self.visibilityRules = visibilityRules
    }

    func supports(_ feature: LanguageFeature, in context: LanguageFeatureRequestContext) -> Bool {
        guard case .navigation = feature,
              context.workspaceURL != nil else { return false }
        return ProjectSymbolNavigation.identifier(
            in: context.text,
            at: context.position
        ) != nil
    }

    func completions(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        completion(.success([]))
    }

    func hover(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        completion(.success(nil))
    }

    func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        guard let rootURL = context.workspaceURL,
              let symbol = ProjectSymbolNavigation.identifier(
                in: context.text,
                at: context.position
              ) else {
            completion(.success([]))
            return
        }

        let operations = operations
        let rules = visibilityRules()
        Task { @MainActor in
            let locations = await Task.detached(priority: .userInitiated) {
                ProjectSymbolNavigation.locations(
                    method: method,
                    symbol: symbol,
                    currentFileURL: context.fileURL,
                    currentText: context.text,
                    rootURL: rootURL,
                    operations: operations,
                    visibilityRules: rules
                )
            }.value
            completion(.success(locations))
        }
    }
}

enum ProjectSymbolNavigation {
    struct Identifier: Equatable, Sendable {
        let value: String
        let range: LanguageServerRange
    }

    private struct RankedLocation: Sendable {
        let location: LanguageServerLocation
        let score: Int
    }

    static func identifier(
        in text: String,
        at position: LanguageServerPosition
    ) -> Identifier? {
        guard position.line >= 0, position.utf16Column >= 0,
              let line = line(in: text, number: position.line) else { return nil }
        let source = line as NSString
        guard source.length > 0 else { return nil }

        var cursor = min(position.utf16Column, source.length)
        if cursor == source.length || !isIdentifierUnit(source.character(at: cursor)) {
            guard cursor > 0, isIdentifierUnit(source.character(at: cursor - 1)) else { return nil }
            cursor -= 1
        }
        var start = cursor
        var end = cursor + 1
        while start > 0, isIdentifierUnit(source.character(at: start - 1)) { start -= 1 }
        while end < source.length, isIdentifierUnit(source.character(at: end)) { end += 1 }
        guard end > start else { return nil }

        let value = source.substring(with: NSRange(location: start, length: end - start))
        return Identifier(
            value: value,
            range: LanguageServerRange(
                start: LanguageServerPosition(line: position.line, utf16Column: start),
                end: LanguageServerPosition(line: position.line, utf16Column: end)
            )
        )
    }

    static func locations(
        method: String,
        symbol: Identifier,
        currentFileURL: URL,
        currentText: String,
        rootURL: URL,
        operations: any WorkspaceOperations,
        visibilityRules: FileVisibilityRules
    ) -> [LanguageServerLocation] {
        var options = ProjectSearchOptions.default
        options.caseSensitive = true
        options.wholeWords = true
        let indexedResults = operations.search(
            at: rootURL,
            query: symbol.value,
            options: options,
            visibilityRules: visibilityRules
        ) ?? []

        let currentURL = currentFileURL.standardizedFileURL
        var requestedLinesByURL: [URL: Set<Int>] = [:]
        for result in indexedResults where result.kind == .content {
            guard let line = result.line, line > 0 else { continue }
            requestedLinesByURL[result.url.standardizedFileURL, default: []].insert(line - 1)
        }
        // The editor buffer can be newer than the on-disk index. Scan it in full
        // and replace any stale indexed view of the same file.
        requestedLinesByURL[currentURL] = Set(currentText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).indices)

        var ranked: [RankedLocation] = []
        for (url, requestedLines) in requestedLinesByURL {
            let source: String
            if url == currentURL {
                source = currentText
            } else {
                guard let relativePath = relativePath(for: url, rootURL: rootURL),
                      let loaded = operations.readFile(at: rootURL, relativePath: relativePath) else {
                    continue
                }
                source = loaded
            }
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for lineNumber in requestedLines.sorted() where lines.indices.contains(lineNumber) {
                let lineText = String(lines[lineNumber])
                for range in exactRanges(of: symbol.value, in: lineText) {
                    let location = LanguageServerLocation(
                        url: url,
                        range: LanguageServerRange(
                            start: LanguageServerPosition(
                                line: lineNumber,
                                utf16Column: range.location
                            ),
                            end: LanguageServerPosition(
                                line: lineNumber,
                                utf16Column: range.location + range.length
                            )
                        )
                    )
                    ranked.append(RankedLocation(
                        location: location,
                        score: structuralScore(
                            method: method,
                            line: lineText,
                            symbolRange: range
                        )
                    ))
                }
            }
        }

        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhsPath = $0.location.url.standardizedFileURL.path
            let rhsPath = $1.location.url.standardizedFileURL.path
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            if $0.location.range.start.line != $1.location.range.start.line {
                return $0.location.range.start.line < $1.location.range.start.line
            }
            return $0.location.range.start.utf16Column < $1.location.range.start.utf16Column
        }

        if method == "textDocument/definition" || method == "textDocument/implementation" {
            let structural = ranked.filter { $0.score > 0 }
            if !structural.isEmpty { ranked = structural }
        }
        return Array(ranked.prefix(500).map(\.location))
    }

    private static func exactRanges(of symbol: String, in line: String) -> [NSRange] {
        let source = line as NSString
        let query = symbol as NSString
        guard query.length > 0 else { return [] }
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let match = source.range(of: symbol, options: .literal, range: searchRange)
            guard match.location != NSNotFound else { break }
            let leftIsBoundary = match.location == 0 ||
                !isIdentifierUnit(source.character(at: match.location - 1))
            let matchEnd = match.location + match.length
            let rightIsBoundary = matchEnd == source.length ||
                !isIdentifierUnit(source.character(at: matchEnd))
            if leftIsBoundary && rightIsBoundary { result.append(match) }
            let next = max(matchEnd, match.location + 1)
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return result
    }

    private static func structuralScore(method: String, line: String, symbolRange: NSRange) -> Int {
        let prefix = (line as NSString).substring(to: symbolRange.location).lowercased()
        let tokens = prefix.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        let nearby = Set(tokens.suffix(4).map(String.init))
        let definitionMarkers: Set<String> = [
            "class", "struct", "interface", "protocol", "trait", "enum", "record", "union",
            "type", "typealias", "func", "function", "fn", "def", "const", "let", "var"
        ]
        let implementationMarkers: Set<String> = ["impl", "implements", "override", "extension"]
        switch method {
        case "textDocument/implementation":
            return nearby.intersection(implementationMarkers).isEmpty ? 0 : 2
        case "textDocument/definition":
            return nearby.intersection(definitionMarkers).isEmpty ? 0 : 2
        default:
            return 0
        }
    }

    private static func line(in text: String, number: Int) -> String? {
        guard number >= 0 else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.indices.contains(number) else { return nil }
        return String(lines[number])
    }

    private static func isIdentifierUnit(_ unit: unichar) -> Bool {
        switch unit {
        case 48...57, 65...90, 97...122, 95, 36:
            return true
        default:
            // Treat non-ASCII UTF-16 units as identifier constituents. This
            // keeps Unicode identifiers intact without assuming a language.
            return unit >= 0x80
        }
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
