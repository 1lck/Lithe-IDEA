import Foundation

enum WorkspaceScanner {
    private static let excludedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "target", "build",
        "DerivedData", ".gradle", ".next", "dist", "coverage", "design-qa-artifacts"
    ]
    private static let excludedNames: Set<String> = [".DS_Store"]

    static func snapshot(at rootURL: URL) -> WorkspaceSnapshot {
        var indexedFiles: [URL] = []
        let root = makeNode(at: rootURL, indexedFiles: &indexedFiles)
        return WorkspaceSnapshot(root: root, files: indexedFiles)
    }

    static func searchableFiles(from files: [URL]) -> [URL] {
        files.filter(isReadableTextFile)
    }

    static func search(query: String, root: URL, files: [URL], limit: Int = 200) -> [FileSearchResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let lowercasedQuery = normalized.lowercased()
        var results: [FileSearchResult] = []

        for file in files {
            if results.count >= limit { break }
            let relativePath = relativePath(for: file, root: root)
            if relativePath.lowercased().contains(lowercasedQuery) {
                results.append(FileSearchResult(url: file, line: nil, preview: relativePath))
            }

            guard results.count < limit,
                  isReadableTextFile(file),
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                  data.count <= 2_000_000,
                  let contents = String(data: data, encoding: .utf8) else { continue }

            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(normalized) {
                    results.append(FileSearchResult(
                        url: file,
                        line: index + 1,
                        preview: line.trimmingCharacters(in: .whitespaces)
                    ))
                    if results.count >= limit { break }
                }
            }
        }
        return results
    }

    static func searchEverywhere(
        query: String,
        root: URL,
        files: [URL],
        fileLimit: Int = 50,
        contentLimit: Int = 50
    ) -> SearchEverywhereResults {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return SearchEverywhereResults(fileMatches: [], contentMatches: []) }

        let lowercasedQuery = normalized.lowercased()
        var fileMatches: [FileSearchResult] = []
        var contentMatches: [FileSearchResult] = []
        let searchable = files.filter(isReadableTextFile)

        for file in searchable {
            let relativePath = relativePath(for: file, root: root)
            if fileMatches.count < fileLimit,
               relativePath.lowercased().contains(lowercasedQuery) {
                fileMatches.append(FileSearchResult(url: file, line: nil, preview: relativePath))
            }

            guard contentMatches.count < contentLimit,
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                  data.count <= 2_000_000,
                  let contents = String(data: data, encoding: .utf8) else { continue }

            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(normalized) {
                    contentMatches.append(FileSearchResult(
                        url: file,
                        line: index + 1,
                        preview: line.trimmingCharacters(in: .whitespaces)
                    ))
                    if contentMatches.count >= contentLimit { break }
                }
            }
        }
        return SearchEverywhereResults(fileMatches: fileMatches, contentMatches: contentMatches)
    }

    static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isReadableTextFile(_ url: URL) -> Bool {
        let textExtensions: Set<String> = [
            "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json",
            "jsx", "kt", "kts", "md", "m", "mm", "php", "plist", "properties", "py", "rb",
            "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
        ]
        return textExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.isEmpty
    }

    private static func makeNode(at url: URL, indexedFiles: inout [URL]) -> FileNode {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard isDirectory.boolValue else {
            indexedFiles.append(url)
            return FileNode(url: url, isDirectory: false, children: nil)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        )) ?? []

        let visibleURLs = urls.filter { child in
            guard !excludedDirectories.contains(child.lastPathComponent),
                  !excludedNames.contains(child.lastPathComponent) else { return false }
            let values = try? child.resourceValues(forKeys: Set(keys))
            return values?.isSymbolicLink != true
        }

        let sortedURLs = visibleURLs.sorted { lhs, rhs in
            let leftDirectory = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let rightDirectory = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if leftDirectory != rightDirectory { return leftDirectory }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        let children = sortedURLs.map { makeNode(at: $0, indexedFiles: &indexedFiles) }
        return FileNode(url: url, isDirectory: true, children: children)
    }
}
