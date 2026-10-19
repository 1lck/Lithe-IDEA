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
    /// Besides `ignoredDirectories`, this covers the private state of other
    /// linked worktrees under `<common>/worktrees/<id>`: agent tools update
    /// those indexes on every Git command, but only this workspace's own Git
    /// directory and the shared refs change what it shows.
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
        return true
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
