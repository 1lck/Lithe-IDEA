import Foundation

/// Reads the branch a project had checked out when it was last opened.
///
/// The welcome list persists this value as recent-project metadata so showing
/// it never launches Git or waits for the Git module to load.
protocol RecentProjectBranchReading: Sendable {
    func branch(forProjectAt url: URL) -> String?
}

/// Fixtures and tests that do not exercise Git metadata use this reader.
struct UnavailableRecentProjectBranchReader: RecentProjectBranchReading {
    func branch(forProjectAt url: URL) -> String? { nil }
}
