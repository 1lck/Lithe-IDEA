import Foundation

/// Recommended names for language-server generated clutter.
///
/// Settings offers one-shot add/remove actions against this list; Lithe does not
/// keep a persistent toggle or re-sync after the user edits the resulting
/// rules. `.factorypath` is the current JDTLS / m2e-apt output; files remain on
/// disk either way. Add future LSP artifact names here.
package enum LSPGeneratedArtifactVisibility {
    package static let filePatterns = [".factorypath"]

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
    package static func applying(patterns: [String], adding: Bool, to existing: String) -> String {
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

        if adding {
            var present = Set(lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            for pattern in patterns {
                let normalized = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !present.contains(normalized) else { continue }
                lines.append(normalized)
                present.insert(normalized)
            }
        } else {
            // Explicit remove only. Missing managed lines are a no-op.
            lines.removeAll { managed.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        if lines.isEmpty {
            return existing.isEmpty ? "" : "\n"
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One-shot writes of managed ignore patterns into the worktree-aware `info/exclude`.
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

    package func applyManagedPatterns(
        adding: Bool,
        patterns: [String],
        at workspaceURL: URL
    ) async throws {
        guard let context = await gitWatchContextProvider.watchContext(for: workspaceURL) else {
            return
        }
        let excludeURL = context.localExcludeFileURL
        let existing: String
        if fileOperations.fileExists(at: excludeURL) {
            existing = try fileOperations.readText(from: excludeURL)
        } else if !adding {
            // Remove is a no-op when the exclude file is absent.
            return
        } else {
            existing = ""
        }
        let updated = GitIgnoreFileText.applying(patterns: patterns, adding: adding, to: existing)
        guard updated != existing else { return }
        try fileOperations.createDirectory(
            at: excludeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileOperations.writeText(updated, to: excludeURL)
    }
}
