import Foundation

protocol WorkspaceOperations: Sendable {
    func snapshot(
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> WorkspaceSnapshot?

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]?

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults?

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]?

    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules)
    func updateSearchIndex(
        at rootURL: URL,
        changedPaths: [String],
        visibilityRules: FileVisibilityRules
    )
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules)

    func readFile(at rootURL: URL, relativePath: String) -> String?
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool
}

extension WorkspaceOperations {
    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {}

    func updateSearchIndex(
        at rootURL: URL,
        changedPaths: [String],
        visibilityRules: FileVisibilityRules
    ) {}

    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {}
}

struct RustWorkspaceOperations: WorkspaceOperations, Sendable {
    let core: RustCoreBridge

    func snapshot(
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> WorkspaceSnapshot? {
        if let snapshot = core.snapshot(
            at: rootURL,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeSnapshot(at: rootURL) {
            return snapshot
        }
        return FileSystemWorkspaceSnapshotBuilder().snapshot(
            at: rootURL,
            visibilityRules: visibilityRules
        )
    }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? {
        core.search(
            at: rootURL,
            query: query,
            caseSensitive: options.caseSensitive,
            wholeWords: options.wholeWords,
            regularExpression: options.regularExpression,
            fileMask: options.fileMask,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeResults(at: rootURL)
    }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? {
        core.searchEverywhere(
            at: rootURL,
            query: query,
            caseSensitive: options.caseSensitive,
            wholeWords: options.wholeWords,
            regularExpression: options.regularExpression,
            maxResults: SearchEverywhereResults.matchLimit,
            maxFileResults: 50,
            maxContentResults: 50,
            maxSymbolResults: 50,
            fileMask: options.fileMask,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeEverywhereResults(at: rootURL)
    }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? {
        core.previewReplacement(
            at: rootURL,
            query: query,
            replacement: replacement,
            caseSensitive: options.caseSensitive,
            wholeWords: options.wholeWords,
            regularExpression: options.regularExpression,
            preserveCase: options.preserveCase,
            fileMask: options.fileMask,
            paths: paths,
            textOverrides: textOverrides,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.makeModels(at: rootURL)
    }

    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {
        core.warmSearchIndex(
            at: rootURL,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )
    }

    func updateSearchIndex(
        at rootURL: URL,
        changedPaths: [String],
        visibilityRules: FileVisibilityRules
    ) {
        core.updateSearchIndex(
            at: rootURL,
            changedPaths: changedPaths,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )
    }

    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {
        core.invalidateSearchIndex(
            at: rootURL,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )
    }

    func readFile(at rootURL: URL, relativePath: String) -> String? {
        core.readFile(at: rootURL, relativePath: relativePath)?.text
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool {
        core.writeFile(text, at: rootURL, relativePath: relativePath) != nil
    }
}

/// Keeps the project tree usable when the native Core is unavailable or a
/// snapshot request fails. Search and advanced project services continue to
/// use Core; this fallback only prevents a readable folder becoming an empty
/// project tab.
struct FileSystemWorkspaceSnapshotBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func snapshot(
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> WorkspaceSnapshot? {
        let rootURL = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        var files: [URL] = []
        guard let root = scan(
            rootURL,
            rootURL: rootURL,
            visibilityRules: visibilityRules,
            files: &files,
            isRoot: true
        ) else {
            return nil
        }
        return WorkspaceSnapshot(root: root, files: files)
    }

    private func scan(
        _ url: URL,
        rootURL: URL,
        visibilityRules: FileVisibilityRules,
        files: inout [URL],
        isRoot: Bool = false
    ) -> FileNode? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              isRoot || values.isSymbolicLink != true else {
            return nil
        }
        let isDirectory = values.isDirectory == true
        guard isRoot || !visibilityRules.isHidden(url, relativeTo: rootURL, isDirectory: isDirectory) else {
            return nil
        }
        guard isDirectory else {
            files.append(url)
            return FileNode(url: url, isDirectory: false, children: nil)
        }

        let childURLs = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
        let children = childURLs.compactMap { childURL in
            scan(
                childURL,
                rootURL: rootURL,
                visibilityRules: visibilityRules,
                files: &files
            )
        }.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        return FileNode(url: url, isDirectory: true, children: children)
    }
}
