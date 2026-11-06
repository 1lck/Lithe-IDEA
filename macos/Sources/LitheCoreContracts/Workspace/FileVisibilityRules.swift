import Foundation

/// The user's hidden-path entries plus the questions hosts ask about them.
///
/// The built-in lists, the glob matcher and the file-versus-folder rules live in Rust Core
/// (`lithe-core-rules`, shared with Windows). This type keeps only what the user wrote and
/// forwards every question to `FileVisibilityEngines`; it has no list and no matcher of its own.
package struct FileVisibilityRules: Hashable, Sendable {
    /// VCS metadata (`.git`, `.svn`) is hidden like IDEA's default ignore list; providers watch
    /// their own metadata directories.
    package static var builtInHiddenDirectories: [String] { FileVisibilityEngines.defaults.hiddenDirectoryNames }
    /// Names and globs omitted from the project tree, search index, watchers, and Local History.
    /// LSP-generated artifacts are not built-in; users can add them once via the Hidden paths
    /// recommended-rules actions.
    package static var builtInHiddenFilePatterns: [String] { FileVisibilityEngines.defaults.hiddenFilePatterns }
    /// The project configuration folder is hidden like IDEA's `.idea`; its files are edited
    /// through Settings and the run configuration editor.
    package static var hiddenConfigurationPattern: String { FileVisibilityEngines.defaults.configurationPattern }
    /// The built-in rules written as Hidden paths patterns, for display.
    package static var builtInPatterns: [String] { FileVisibilityEngines.defaults.builtInPatterns }

    /// The project configuration folder at the workspace root. It is the only folder a
    /// hidden-path rule may remove from the tree while its file events stay watched, because
    /// edits to its JSON files reload project services.
    package static var watchedConfigurationDirectory: String { FileVisibilityEngines.defaults.configurationDirectory }

    /// The user's folder names, as stored. Core adds the built-ins when it evaluates them.
    package var hiddenDirectoryNames: [String]
    /// The user's patterns, as stored. A `!` entry turns a built-in rule off; it stays in the
    /// list so Core, which adds the built-ins, drops the same ones.
    package var hiddenFilePatterns: [String]

    /// Only the built-in rules.
    package static let `default` = FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])

    package init(hiddenDirectoryNames: [String], hiddenFilePatterns: [String]) {
        self.hiddenDirectoryNames = hiddenDirectoryNames
        self.hiddenFilePatterns = hiddenFilePatterns
    }

    /// Whether `pattern` is one of `builtInPatterns`, ignoring case.
    package static func isBuiltInPattern(_ pattern: String) -> Bool {
        builtInPatterns.contains { $0.caseInsensitiveCompare(pattern) == .orderedSame }
    }

    /// Whether `name` is one of the built-in folder names, ignoring case.
    package static func isBuiltInDirectoryName(_ name: String) -> Bool {
        builtInHiddenDirectories.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The entries after a leading `!`. Settings text syntax; Core applies the same rule when it
    /// evaluates the list.
    package static func disabledEntries(_ patterns: [String]) -> [String] {
        patterns.compactMap { pattern in
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("!") else { return nil }
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    package func isHidden(
        _ url: URL,
        relativeTo rootURL: URL,
        isDirectory: Bool? = nil
    ) -> Bool {
        verdict(for: url, relativeTo: rootURL, isDirectory: isDirectory)?.hidden ?? false
    }

    package func isHiddenPath(_ url: URL, relativeTo rootURL: URL) -> Bool {
        isHidden(url, relativeTo: rootURL, isDirectory: nil)
    }

    /// Classifies a whole listing with one Core call. Prefer this over `isHidden` in loops.
    package func hiddenFlags(
        for entries: [(url: URL, isDirectory: Bool?)],
        relativeTo rootURL: URL
    ) -> [Bool] {
        let queries = entries.map {
            (relative: Self.relativePath(for: $0.url, root: rootURL), isDirectory: $0.isDirectory)
        }
        let asked = queries.enumerated().filter { !$0.element.relative.isEmpty }
        guard !asked.isEmpty else { return Array(repeating: false, count: entries.count) }
        let verdicts = FileVisibilityEngines.current.classify(
            asked.map { FileVisibilityQuery(relativePath: $0.element.relative, isDirectory: $0.element.isDirectory) },
            hiddenDirectoryNames: hiddenDirectoryNames,
            hiddenFilePatterns: hiddenFilePatterns
        )
        var flags = Array(repeating: false, count: entries.count)
        for (position, item) in asked.enumerated() where position < verdicts.count {
            flags[item.offset] = verdicts[position].hidden
        }
        return flags
    }

    /// Whether file events at `url` must still be delivered although the rules hide it. Only the
    /// built-in noise below the configuration folder, such as `.lithe/run/local.json`, stays dropped.
    package func isWatchedDespiteHiding(_ url: URL, relativeTo rootURL: URL) -> Bool {
        verdict(for: url, relativeTo: rootURL, isDirectory: nil)?.watchedDespiteHiding ?? false
    }

    /// Whether a file event at `url` belongs to visible project inputs: the path is not hidden, or
    /// it is hidden but still watched. One Core call answers both parts.
    package func deliversEvents(at url: URL, relativeTo rootURL: URL) -> Bool {
        guard let verdict = verdict(for: url, relativeTo: rootURL, isDirectory: nil) else { return true }
        return !verdict.hidden || verdict.watchedDespiteHiding
    }

    private func verdict(for url: URL, relativeTo rootURL: URL, isDirectory: Bool?) -> FileVisibilityVerdict? {
        let relativePath = Self.relativePath(for: url, root: rootURL)
        guard !relativePath.isEmpty else { return nil }
        return FileVisibilityEngines.current.classify(
            [FileVisibilityQuery(relativePath: relativePath, isDirectory: isDirectory)],
            hiddenDirectoryNames: hiddenDirectoryNames,
            hiddenFilePatterns: hiddenFilePatterns
        ).first
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
