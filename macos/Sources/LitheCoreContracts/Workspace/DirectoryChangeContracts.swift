import Foundation


package struct DirectoryWatchConfiguration: Equatable, Sendable {
    package let workspaceRoot: URL
    package let repositoryRoot: URL?
    package let gitDirectory: URL?
    package let gitCommonDirectory: URL?
    /// Workspace directories whose events are dropped, such as linked worktrees
    /// checked out inside the workspace's own repository.
    package let ignoredDirectories: [URL]

    package init(
        workspaceRoot: URL,
        gitContext: GitWatchContext?,
        ignoredDirectories: [URL] = []
    ) {
        self.workspaceRoot = Self.normalize(workspaceRoot)
        repositoryRoot = gitContext.map { Self.normalize($0.repositoryRoot) }
        gitDirectory = gitContext.map { Self.normalize($0.gitDirectory) }
        gitCommonDirectory = gitContext.map { Self.normalize($0.gitCommonDirectory) }
        self.ignoredDirectories = ignoredDirectories.map(Self.normalize).sorted { $0.path < $1.path }
    }

    /// Whether a change cannot affect this workspace's tree or Git status.
    ///
    /// Besides `ignoredDirectories`, this covers the high-frequency private
    /// state of other linked worktrees under `<common>/worktrees/<id>`: every
    /// Git command in those worktrees rewrites their index, reflogs, and
    /// submodule scratch state, but only the shared refs and this workspace's
    /// own Git directory change what it shows. Their semantic metadata (such as
    /// `HEAD`, `locked`, or registration files) is not ignored, so the
    /// Worktrees panel still refreshes.
    package func isIgnored(_ url: URL) -> Bool {
        let normalized = Self.normalize(url)
        if ignoredDirectories.contains(where: { Self.contains($0, normalized) }) {
            return true
        }
        guard let gitCommonDirectory else { return false }
        let linkedWorktrees = gitCommonDirectory.appendingPathComponent("worktrees", isDirectory: true)
        guard Self.contains(linkedWorktrees, normalized) else { return false }
        // A linked workspace keeps its own state under `worktrees/<self>`.
        if let gitDirectory, gitDirectory != gitCommonDirectory,
           Self.contains(gitDirectory, normalized) {
            return false
        }
        guard let relativePath = Self.relativePath(of: normalized, below: linkedWorktrees) else {
            return false
        }
        // `<id>` alone is the registration directory itself; only entry names
        // one level below it are high-frequency private state.
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return false }
        return Self.highChurnLinkedWorktreeEntries.contains(components[1])
    }

    /// Entries under another linked worktree's Git directory that every Git
    /// command rewrites there. Changes to them cannot alter this workspace's
    /// tree, status, or worktree list.
    private static let highChurnLinkedWorktreeEntries: Set<String> = [
        "index",
        "index.lock",
        "ORIG_HEAD",
        "logs",
        "modules",
    ]

    /// The excluded workspace directory that owns `url`, if any.
    package func ignoredDirectoryRoot(containing url: URL) -> URL? {
        let normalized = Self.normalize(url)
        return ignoredDirectories.first { Self.contains($0, normalized) }
    }

    /// Whether an event can change whether an excluded linked worktree is still
    /// excluded.
    ///
    /// Its ordinary descendants stay ignored, but the directory itself being
    /// created, removed, or renamed, or its `.git` marker changing, may mean
    /// the path is now ordinary workspace content. Only a scan can re-run the
    /// linked-worktree rules and rebuild `ignoredDirectories`.
    package func revalidatesIgnoredDirectory(_ url: URL, isStructuralChange: Bool) -> Bool {
        guard let root = ignoredDirectoryRoot(containing: url) else { return false }
        let normalized = Self.normalize(url)
        if normalized.path == root.path { return isStructuralChange }
        return normalized.path == root.path + "/.git"
    }

    package var physicalRoots: [URL] {
        let logicalRoots = [workspaceRoot, repositoryRoot, gitDirectory, gitCommonDirectory]
            .compactMap { $0 }
        var seen = Set<String>()
        let uniqueRoots = logicalRoots
            .filter { seen.insert($0.path).inserted }
            .sorted {
                if $0.path.count == $1.path.count { return $0.path < $1.path }
                return $0.path.count < $1.path.count
            }
        return uniqueRoots.filter { candidate in
            !uniqueRoots.contains { root in
                root.path != candidate.path && Self.contains(root, candidate)
            }
        }
    }

    package func containsWorkspacePath(_ url: URL) -> Bool {
        Self.contains(workspaceRoot, Self.normalize(url))
    }

    package func containsRepositoryPath(_ url: URL) -> Bool {
        guard let repositoryRoot else { return false }
        return Self.contains(repositoryRoot, Self.normalize(url))
    }

    package func containsGitMetadataPath(_ url: URL) -> Bool {
        let normalized = Self.normalize(url)
        return [gitDirectory, gitCommonDirectory]
            .compactMap { $0 }
            .contains { Self.contains($0, normalized) }
    }

    package func isGitContextPointer(_ url: URL) -> Bool {
        let normalized = Self.normalize(url)
        let candidates = [workspaceRoot, repositoryRoot]
            .compactMap { $0 }
            .map { $0.appendingPathComponent(".git").standardizedFileURL.path }
        return candidates.contains(normalized.path)
    }

    package func isLogicalRoot(_ url: URL) -> Bool {
        let path = Self.normalize(url).path
        return [workspaceRoot, repositoryRoot, gitDirectory, gitCommonDirectory]
            .compactMap { $0 }
            .contains { $0.path == path }
    }

    private static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }

    private static func relativePath(of url: URL, below parent: URL) -> String? {
        guard url.path.hasPrefix(parent.path + "/") else { return nil }
        return String(url.path.dropFirst(parent.path.count + 1))
    }
}

package struct DirectoryChangeBatch: Equatable, Sendable {
    package var workspacePaths: [String]
    package var gitStateMayHaveChanged: Bool
    package var requiresFullRescan: Bool
    package var watchRootsChanged: Bool

    package init(
        workspacePaths: [String] = [],
        gitStateMayHaveChanged: Bool = false,
        requiresFullRescan: Bool = false,
        watchRootsChanged: Bool = false
    ) {
        self.workspacePaths = workspacePaths
        self.gitStateMayHaveChanged = gitStateMayHaveChanged
        self.requiresFullRescan = requiresFullRescan
        self.watchRootsChanged = watchRootsChanged
    }

    package var isEmpty: Bool {
        workspacePaths.isEmpty && !gitStateMayHaveChanged && !requiresFullRescan && !watchRootsChanged
    }
}

/// A coalesced filesystem change projected after the workspace snapshot has
/// identified whether the path was previously known.
package struct WorkspaceFileChange: Equatable, Sendable {
    package enum Kind: String, Equatable, Sendable {
        case created
        case changed
        case deleted
    }

    package let fileURL: URL
    package let kind: Kind

    package init(fileURL: URL, kind: Kind) {
        self.fileURL = fileURL.standardizedFileURL
        self.kind = kind
    }
}

package protocol DirectoryChangeSource: AnyObject, Sendable {
    func start()
    func stop()
}
