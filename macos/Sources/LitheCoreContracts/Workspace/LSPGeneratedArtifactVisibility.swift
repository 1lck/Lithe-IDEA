import Foundation

/// Opt-in names for language-server generated clutter.
///
/// The settings toggle stays generic so later artifact types can be added here
/// without coupling the UI to a single filename. `.factorypath` is the current
/// JDTLS / m2e-apt output; files remain on disk either way.
package enum LSPGeneratedArtifactVisibility {
    package static let filePatterns = [".factorypath"]

    package static func applying(enabled: Bool, to patterns: [String]) -> [String] {
        enabled ? inserting(into: patterns) : removing(from: patterns)
    }

    package static func inserting(into patterns: [String]) -> [String] {
        var result = patterns
        for pattern in filePatterns {
            let exists = result.contains { $0.caseInsensitiveCompare(pattern) == .orderedSame }
            if !exists {
                result.append(pattern)
            }
        }
        return result
    }

    package static func removing(from patterns: [String]) -> [String] {
        patterns.filter { candidate in
            !filePatterns.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
    }
}

/// Inserts or removes managed Git ignore lines while preserving unrelated rules.
package enum GitIgnoreFileText {
    package static func applying(patterns: [String], enabled: Bool, to existing: String) -> String {
        let managed = Set(
            patterns
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !managed.isEmpty else { return existing }

        var lines = existing.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }

        if enabled {
            var present = Set(lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            for pattern in patterns {
                let normalized = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !present.contains(normalized) else { continue }
                lines.append(normalized)
                present.insert(normalized)
            }
        } else {
            lines.removeAll { managed.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        if lines.isEmpty {
            return existing.isEmpty ? "" : "\n"
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Writes managed ignore patterns into `.git/info/exclude` for the current checkout.
package struct GitLocalExcludeSynchronizer: Sendable {
    private let fileOperations: any WorkspaceFileOperations
    private let gitWatchContextProvider: any GitWatchContextProviding

    package init(
        fileOperations: any WorkspaceFileOperations,
        gitWatchContextProvider: any GitWatchContextProviding
    ) {
        self.fileOperations = fileOperations
        self.gitWatchContextProvider = gitWatchContextProvider
    }

    package func synchronize(
        enabled: Bool,
        patterns: [String],
        at workspaceURL: URL
    ) async throws {
        guard let context = await gitWatchContextProvider.watchContext(for: workspaceURL) else {
            return
        }
        let excludeURL = context.gitDirectory.appendingPathComponent("info/exclude")
        let existing: String
        if fileOperations.fileExists(at: excludeURL) {
            existing = try fileOperations.readText(from: excludeURL)
        } else {
            existing = ""
        }
        let updated = GitIgnoreFileText.applying(patterns: patterns, enabled: enabled, to: existing)
        guard updated != existing else { return }
        try fileOperations.createDirectory(
            at: excludeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileOperations.writeText(updated, to: excludeURL)
    }
}
