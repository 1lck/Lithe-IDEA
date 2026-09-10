import Foundation

/// Recommended names for language-server generated clutter.
///
/// Settings offers one-shot add/remove actions against this list; Lithe does not
/// keep a persistent toggle or re-sync after the user edits the resulting
/// rules. `.factorypath` is the current JDTLS / m2e-apt output; files remain on
/// disk either way. Add future LSP artifact names here.
///
/// Git local exclude mutations for these patterns go through Rust Core
/// `git.write` (`excludePatterns` / `unexcludePatterns`), not a Swift IO path.
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
