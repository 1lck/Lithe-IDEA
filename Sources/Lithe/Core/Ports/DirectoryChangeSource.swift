import Foundation


struct DirectoryWatchConfiguration: Equatable, Sendable {
    let workspaceRoot: URL
    let repositoryRoot: URL?
    let gitDirectory: URL?
    let gitCommonDirectory: URL?

    init(workspaceRoot: URL, gitContext: GitWatchContext?) {
        self.workspaceRoot = Self.normalize(workspaceRoot)
        repositoryRoot = gitContext.map { Self.normalize($0.repositoryRoot) }
        gitDirectory = gitContext.map { Self.normalize($0.gitDirectory) }
        gitCommonDirectory = gitContext.map { Self.normalize($0.gitCommonDirectory) }
    }

    var physicalRoots: [URL] {
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

    func containsWorkspacePath(_ url: URL) -> Bool {
        Self.contains(workspaceRoot, Self.normalize(url))
    }

    func containsRepositoryPath(_ url: URL) -> Bool {
        guard let repositoryRoot else { return false }
        return Self.contains(repositoryRoot, Self.normalize(url))
    }

    func containsGitMetadataPath(_ url: URL) -> Bool {
        let normalized = Self.normalize(url)
        return [gitDirectory, gitCommonDirectory]
            .compactMap { $0 }
            .contains { Self.contains($0, normalized) }
    }

    func isGitContextPointer(_ url: URL) -> Bool {
        let normalized = Self.normalize(url)
        let candidates = [workspaceRoot, repositoryRoot]
            .compactMap { $0 }
            .map { $0.appendingPathComponent(".git").standardizedFileURL.path }
        return candidates.contains(normalized.path)
    }

    func isLogicalRoot(_ url: URL) -> Bool {
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

struct DirectoryChangeBatch: Equatable, Sendable {
    var workspacePaths: [String]
    var gitStateMayHaveChanged: Bool
    var requiresFullRescan: Bool
    var watchRootsChanged: Bool

    init(
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

    var isEmpty: Bool {
        workspacePaths.isEmpty && !gitStateMayHaveChanged && !requiresFullRescan && !watchRootsChanged
    }
}

protocol DirectoryChangeSource: AnyObject {
    func start()
    func stop()
}
