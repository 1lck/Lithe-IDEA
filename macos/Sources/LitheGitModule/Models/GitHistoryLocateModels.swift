import Foundation

/// Result of Core's `git.historyLocate`: the shared bounded walk that finds a
/// commit outside the loaded history window.
package struct GitHistoryLocateResult: Sendable {
    /// Whether the requested `target` was read within the page budget.
    package let found: Bool
    /// Commits read after the requested cursor, in reading order. The caller
    /// deduplicates them against its loaded window before appending.
    package let commits: [GitCommit]
    /// Cursor after the last read page. `nil` when the walk read history to the
    /// end, or the target was found on the final page.
    package let nextCursor: String?
    /// Whether more history exists after `nextCursor`.
    package let hasMore: Bool
    /// Pages actually read, bounded by the request's page budget.
    package let pagesLoaded: Int

    package init(
        found: Bool,
        commits: [GitCommit],
        nextCursor: String?,
        hasMore: Bool,
        pagesLoaded: Int
    ) {
        self.found = found
        self.commits = commits
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.pagesLoaded = pagesLoaded
    }
}
