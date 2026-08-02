import Foundation

actor WorkspaceSearchIndex {
    private static let indexVersion = 1
    private static let maximumIndexedFileSize = 2 * 1_024 * 1_024

    private struct IndexEntry: Codable, Sendable {
        let relativePath: String
        let byteCount: Int
        let modificationDate: Date?
        let isSearchable: Bool
        let tokens: [String]
        let symbols: [SearchSymbol]
    }

    private struct PersistedIndex: Codable, Sendable {
        let version: Int
        let rootPath: String
        let entries: [IndexEntry]
    }

    private var rootURL: URL?
    private var entries: [String: IndexEntry] = [:]
    private var indexURL: URL?

    func configure(at rootURL: URL) {
        let normalizedRoot = rootURL.standardizedFileURL
        guard self.rootURL?.path != normalizedRoot.path else { return }

        self.rootURL = normalizedRoot
        indexURL = Self.indexURL(for: normalizedRoot)
        entries = loadEntries(rootURL: normalizedRoot, indexURL: indexURL)
    }

    func reset() {
        rootURL = nil
        entries = [:]
        indexURL = nil
    }

    func update(files: [URL]) {
        guard let rootURL else { return }
        updateIfNeeded(files: files, rootURL: rootURL)
    }

    func searchProject(
        query: String,
        files: [URL],
        options: ProjectSearchOptions = .default
    ) -> [FileSearchResult] {
        guard let rootURL else { return [] }
        updateIfNeeded(files: files, rootURL: rootURL)
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var results: [FileSearchResult] = []
        let orderedEntries = entries.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        for entry in orderedEntries {
            guard results.count < 200 else { break }
            let fileURL = rootURL.appendingPathComponent(entry.relativePath)
            if options.matches(entry.relativePath, query: normalized) {
                results.append(FileSearchResult(
                    url: fileURL,
                    line: nil,
                    preview: entry.relativePath,
                    kind: .file
                ))
            }
        }

        results.append(contentsOf: contentMatches(
            query: normalized,
            entries: orderedEntries,
            rootURL: rootURL,
            limit: max(0, 200 - results.count),
            options: options
        ))
        return results
    }

    func searchEverywhere(
        query: String,
        files: [URL],
        options: ProjectSearchOptions = .default
    ) -> SearchEverywhereResults {
        guard let rootURL else { return SearchEverywhereResults() }
        updateIfNeeded(files: files, rootURL: rootURL)
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return SearchEverywhereResults() }

        let orderedEntries = entries.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        let fileMatches = orderedEntries
            .filter { options.matches($0.relativePath, query: normalized) }
            .prefix(50)
            .map { entry in
                FileSearchResult(
                    url: rootURL.appendingPathComponent(entry.relativePath),
                    line: nil,
                    preview: entry.relativePath,
                    kind: .file
                )
            }

        var classMatches: [FileSearchResult] = []
        var symbolMatches: [FileSearchResult] = []
        for entry in orderedEntries {
            for symbol in entry.symbols where options.matches(symbol.name, query: normalized) {
                let result = FileSearchResult(
                    url: rootURL.appendingPathComponent(entry.relativePath),
                    line: symbol.line,
                    preview: symbol.signature,
                    kind: symbol.kind,
                    symbolName: symbol.name
                )
                if symbol.kind == .type {
                    if classMatches.count < 50 { classMatches.append(result) }
                } else if symbolMatches.count < 50 {
                    symbolMatches.append(result)
                }
                if classMatches.count >= 50, symbolMatches.count >= 50 { break }
            }
            if classMatches.count >= 50, symbolMatches.count >= 50 { break }
        }

        return SearchEverywhereResults(
            fileMatches: Array(fileMatches),
            classMatches: classMatches,
            symbolMatches: symbolMatches,
            contentMatches: contentMatches(
                query: normalized,
                entries: orderedEntries,
                rootURL: rootURL,
                limit: 50,
                options: options
            )
        )
    }

    func previewReplacement(
        query: String,
        replacement: String,
        files: [URL],
        textOverrides: [String: String]
    ) -> [ProjectReplacementFile] {
        guard let rootURL else { return [] }
        updateIfNeeded(files: files, rootURL: rootURL)
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let orderedEntries = entries.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return orderedEntries.compactMap { entry in
            let fileURL = rootURL.appendingPathComponent(entry.relativePath)
            let text = textOverrides[fileURL.path] ?? readText(for: fileURL, entry: entry)
            guard let text else { return nil }
            let matches = ProjectReplacementEngine.preview(
                text: text,
                query: normalized,
                replacement: replacement
            )
            guard !matches.isEmpty else { return nil }
            return ProjectReplacementFile(
                url: fileURL,
                relativePath: entry.relativePath,
                matches: matches
            )
        }
    }

    private func updateIfNeeded(files: [URL], rootURL: URL) {
        let normalizedFiles = files.map(\.standardizedFileURL)
        let currentPaths = Set(normalizedFiles.map(\.path))
        var didChange = false

        for key in entries.keys where !currentPaths.contains(rootURL.appendingPathComponent(key).path) {
            entries.removeValue(forKey: key)
            didChange = true
        }

        for fileURL in normalizedFiles {
            let relativePath = WorkspaceScanner.relativePath(for: fileURL, root: rootURL)
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            let byteCount = values?.fileSize ?? 0
            let modificationDate = values?.contentModificationDate
            let isSearchable = values?.isRegularFile == true && WorkspaceScanner.isReadableTextFile(fileURL)
            let existing = entries[relativePath]
            if let existing,
               existing.byteCount == byteCount,
               existing.modificationDate == modificationDate,
               existing.isSearchable == isSearchable {
                continue
            }

            let content = isSearchable ? readText(at: fileURL, byteCount: byteCount) : nil
            entries[relativePath] = IndexEntry(
                relativePath: relativePath,
                byteCount: byteCount,
                modificationDate: modificationDate,
                isSearchable: content != nil,
                tokens: content.map(Self.tokens(in:)) ?? [],
                symbols: content.map { Self.symbols(in: fileURL, source: $0) } ?? []
            )
            didChange = true
        }

        if didChange {
            saveEntries(rootURL: rootURL)
        }
    }

    private func contentMatches(
        query: String,
        entries: [IndexEntry],
        rootURL: URL,
        limit: Int,
        options: ProjectSearchOptions
    ) -> [FileSearchResult] {
        guard limit > 0 else { return [] }
        let queryTokens = options.regularExpression || options.wholeWords
            ? []
            : Self.tokens(in: query)
        let candidates = entries.filter { entry in
            guard entry.isSearchable else { return false }
            guard !queryTokens.isEmpty else { return true }
            return queryTokens.allSatisfy { token in
                entry.tokens.contains(where: { $0.contains(token) })
            }
        }

        var results: [FileSearchResult] = []
        for entry in candidates {
            guard results.count < limit else { break }
            let fileURL = rootURL.appendingPathComponent(entry.relativePath)
            guard let text = readText(for: fileURL, entry: entry) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where options.matches(String(line), query: query) {
                results.append(FileSearchResult(
                    url: fileURL,
                    line: index + 1,
                    preview: line.trimmingCharacters(in: .whitespaces),
                    kind: .content
                ))
                if results.count >= limit { break }
            }
        }
        return results
    }

    private func readText(for fileURL: URL, entry: IndexEntry) -> String? {
        readText(at: fileURL, byteCount: entry.byteCount)
    }

    private func readText(at fileURL: URL, byteCount: Int) -> String? {
        guard byteCount <= Self.maximumIndexedFileSize,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func loadEntries(rootURL: URL, indexURL: URL?) -> [String: IndexEntry] {
        guard let indexURL,
              let data = try? Data(contentsOf: indexURL),
              let persisted = try? JSONDecoder().decode(PersistedIndex.self, from: data),
              persisted.version == Self.indexVersion,
              persisted.rootPath == rootURL.path else { return [:] }
        return Dictionary(uniqueKeysWithValues: persisted.entries.map { ($0.relativePath, $0) })
    }

    private func saveEntries(rootURL: URL) {
        guard let indexURL else { return }
        let persisted = PersistedIndex(
            version: Self.indexVersion,
            rootPath: rootURL.path,
            entries: entries.values.sorted { $0.relativePath < $1.relativePath }
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func indexURL(for rootURL: URL) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("SearchIndex", isDirectory: true)
            .appendingPathComponent(stableIdentifier(for: rootURL.path))
            .appendingPathExtension("json")
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func tokens(in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"[A-Za-z_$][A-Za-z0-9_$]*"#) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Array(Set(expression.matches(in: source, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: source) else { return nil }
            return String(source[tokenRange]).lowercased()
        }))
    }

    private static func symbols(in fileURL: URL, source: String) -> [SearchSymbol] {
        guard fileURL.pathExtension.lowercased() == "java" else { return [] }
        let text = source as NSString
        var symbols: [SearchSymbol] = []

        let typePattern = #"(?m)^[ \t]*(?:(?:public|protected|private|abstract|final|static|sealed|non-sealed)\s+)*(class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#
        if let expression = try? NSRegularExpression(pattern: typePattern) {
            for match in expression.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                guard let nameRange = Range(match.range(at: 2), in: source) else { continue }
                let name = String(source[nameRange])
                symbols.append(SearchSymbol(
                    name: name,
                    kind: .type,
                    line: lineNumber(at: match.range.location, in: text),
                    signature: lineSignature(at: match.range.location, in: text)
                ))
            }
        }

        let methodPattern = #"(?m)^[ \t]*(?:(?:public|protected|private|static|final|abstract|synchronized|native|default|strictfp)\s+)*(?:<[^>\n]+>\s+)?(?:[A-Za-z_$][A-Za-z0-9_$<>,.?\[\]]*\s+)+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^;\n{}]*\)"#
        if let expression = try? NSRegularExpression(pattern: methodPattern) {
            for match in expression.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[nameRange])
                symbols.append(SearchSymbol(
                    name: name,
                    kind: .symbol,
                    line: lineNumber(at: match.range.location, in: text),
                    signature: lineSignature(at: match.range.location, in: text)
                ))
            }
        }

        return Array(Set(symbols)).sorted {
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func lineNumber(at location: Int, in source: NSString) -> Int {
        guard location > 0 else { return 1 }
        let prefix = source.substring(with: NSRange(location: 0, length: min(location, source.length)))
        return prefix.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    private static func lineSignature(at location: Int, in source: NSString) -> String {
        let safeLocation = min(max(0, location), source.length)
        let lineRange = source.lineRange(for: NSRange(location: safeLocation, length: 0))
        return source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
