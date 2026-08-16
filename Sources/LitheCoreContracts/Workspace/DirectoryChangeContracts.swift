import Foundation


package struct DirectoryWatchConfiguration: Equatable, Sendable {
    package let workspaceRoot: URL
    package let repositoryRoot: URL?
    package let gitDirectory: URL?
    package let gitCommonDirectory: URL?

    package init(workspaceRoot: URL, gitContext: GitWatchContext?) {
        self.workspaceRoot = Self.normalize(workspaceRoot)
        repositoryRoot = gitContext.map { Self.normalize($0.repositoryRoot) }
        gitDirectory = gitContext.map { Self.normalize($0.gitDirectory) }
        gitCommonDirectory = gitContext.map { Self.normalize($0.gitCommonDirectory) }
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

package protocol DirectoryChangeSource: AnyObject, Sendable {
    func start()
    func stop()
}
