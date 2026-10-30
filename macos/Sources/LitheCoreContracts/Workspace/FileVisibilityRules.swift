import Foundation

package struct FileVisibilityRules: Hashable, Sendable {
    /// VCS metadata (`.git`, `.svn`) is hidden like IDEA's default ignore
    /// list; providers watch their own metadata directories.
    package static let builtInHiddenDirectories = [
        ".git", ".svn", ".worktree", ".worktrees", ".build", ".swiftpm", "node_modules", ".venv", "venv",
        "__pycache__", "target", "build", "DerivedData", ".gradle", ".next", "dist", "coverage",
        "design-qa-artifacts", ".artifacts"
    ]
    /// Names and globs omitted from the project tree, search index, watchers,
    /// and Local History. LSP-generated artifacts are not built-in; users can
    /// add them once via the Hidden paths recommended-rules actions.
    package static let builtInHiddenFilePatterns = [
        ".DS_Store",
        "*.pyc",
        ".lithe/run/local.json",
    ]

    /// The built-in rules written as Hidden paths patterns, for display. Folder
    /// names become `**/name/`, the pattern that hides them at any depth.
    package static var builtInPatterns: [String] {
        builtInHiddenDirectories.map { "**/\($0)/" } + builtInHiddenFilePatterns
    }

    package var hiddenDirectoryNames: [String]
    package var hiddenFilePatterns: [String]

    package static let `default` = FileVisibilityRules(
        hiddenDirectoryNames: builtInHiddenDirectories,
        hiddenFilePatterns: builtInHiddenFilePatterns
    )

    package init(hiddenDirectoryNames: [String], hiddenFilePatterns: [String]) {
        self.hiddenDirectoryNames = Self.normalizedEntries(
            Self.builtInHiddenDirectories + hiddenDirectoryNames
        )
        self.hiddenFilePatterns = Self.normalizedEntries(
            Self.builtInHiddenFilePatterns + hiddenFilePatterns
        )
    }

    package func isHidden(
        _ url: URL,
        relativeTo rootURL: URL,
        isDirectory: Bool? = nil
    ) -> Bool {
        let relativePath = relativePath(for: url, root: rootURL)
        guard !relativePath.isEmpty else { return false }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let lastComponent = components.last else { return false }

        let directoryComponents: [String]
        switch isDirectory {
        case true:
            directoryComponents = components
        case false:
            directoryComponents = Array(components.dropLast())
        case nil:
            directoryComponents = components
        }
        if directoryComponents.contains(where: isHiddenDirectoryName) {
            return true
        }
        if isDirectory == true, isHiddenDirectoryName(lastComponent) {
            return true
        }

        let directoryCount = isDirectory == false ? max(0, components.count - 1) : components.count
        let folderGlobs = hiddenFilePatterns.compactMap(Self.folderGlob)
        if !folderGlobs.isEmpty {
            // Each ancestor prefix is joined once and shared by every folder
            // rule, instead of being rebuilt per rule.
            let prefixes = stride(from: 1, through: directoryCount, by: 1).map {
                components.prefix($0).joined(separator: "/")
            }
            let hidesFolder = folderGlobs.contains { glob in
                prefixes.contains { Self.pathGlobMatches(glob, value: $0) }
            }
            if hidesFolder { return true }
        }
        guard isDirectory != true else { return false }
        return hiddenFilePatterns.contains { pattern in
            Self.pathGlobMatches(pattern, value: lastComponent) ||
                Self.pathGlobMatches(pattern, value: relativePath)
        }
    }

    package func isHiddenPath(_ url: URL, relativeTo rootURL: URL) -> Bool {
        isHidden(url, relativeTo: rootURL, isDirectory: nil)
    }

    /// The project configuration folder at the workspace root. It is the only
    /// folder a hidden-path rule may remove from the tree while its file events
    /// stay watched, because edits to its JSON files reload project services.
    package static let watchedConfigurationDirectory = ".lithe"

    /// Whether file events at `url` must still be delivered although the rules
    /// hide it. Only the built-in noise below the configuration folder, such as
    /// `.lithe/run/local.json`, stays dropped.
    package func isWatchedDespiteHiding(_ url: URL, relativeTo rootURL: URL) -> Bool {
        let relativePath = relativePath(for: url, root: rootURL)
        guard relativePath.split(separator: "/").first.map(String.init) == Self.watchedConfigurationDirectory
        else { return false }
        return !Self.default.isHiddenPath(url, relativeTo: rootURL)
    }

    package func isHiddenDirectoryName(_ name: String) -> Bool {
        hiddenDirectoryNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The folder glob of an entry that ends in `/`, `/*` or `/**`.
    ///
    /// Such an entry names a folder from the project root (or at any depth when
    /// it starts with `**/`), so the folder and everything below it is hidden
    /// instead of leaving an empty folder behind. Other entries keep their
    /// file-only meaning, as pinned by `shared/fixtures/search/exclusions.json`.
    private static func folderGlob(_ pattern: String) -> String? {
        for suffix in ["/**", "/*", "/"] where pattern.hasSuffix(suffix) {
            let glob = String(pattern.dropLast(suffix.count))
            return glob.isEmpty ? nil : glob
        }
        return nil
    }

    private static func normalizedEntries(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Matches a hidden-path glob, letting a leading `**/` stand for zero or
    /// more folders, so `**/dist/` covers a root-level `dist` as well as
    /// `a/b/dist`. `*` already spans `/`, which covers the non-root case; the
    /// root case needs the second attempt because the glob would otherwise
    /// demand a literal `/`.
    private static func pathGlobMatches(_ pattern: String, value: String) -> Bool {
        if globMatches(pattern, value: value) { return true }
        guard pattern.hasPrefix("**/") else { return false }
        return globMatches(String(pattern.dropFirst(3)), value: value)
    }

    private static func globMatches(_ pattern: String, value: String) -> Bool {
        let patternCharacters = Array(pattern.lowercased())
        let valueCharacters = Array(value.lowercased())
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starMatchIndex = 0

        while valueIndex < valueCharacters.count {
            if patternIndex < patternCharacters.count {
                let character = patternCharacters[patternIndex]
                if character == valueCharacters[valueIndex] || character == "?" {
                    patternIndex += 1
                    valueIndex += 1
                    continue
                }
            }
            if patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
                starIndex = patternIndex
                starMatchIndex = valueIndex
                patternIndex += 1
            } else if let starIndex {
                patternIndex = starIndex + 1
                starMatchIndex += 1
                valueIndex = starMatchIndex
            } else {
                return false
            }
        }

        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }
}
