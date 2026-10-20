import Foundation

/// macOS fallback used when Rust cannot provide a workspace snapshot.
struct FileSystemWorkspaceSnapshotBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        let rootURL = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        var nestedWorktrees: [URL] = []
        guard let root = scan(rootURL, rootURL: rootURL, visibilityRules: visibilityRules, nestedWorktrees: &nestedWorktrees, isRoot: true) else { return nil }
        return WorkspaceSnapshot(root: root, files: root.fileURLs, nestedWorktrees: nestedWorktrees.sorted { $0.path < $1.path })
    }

    /// One visible level below each directory, filtered like `scan`.
    func listDirectories(
        _ directories: [URL],
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> [String: [ProjectDirectoryEntry]] {
        var result: [String: [ProjectDirectoryEntry]] = [:]
        for directory in directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let childURLs = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: []
                  ) else { continue }
            let entries = childURLs.compactMap { url -> ProjectDirectoryEntry? in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { return nil }
                let isDirectory = values.isDirectory == true
                guard !visibilityRules.isHidden(url, relativeTo: rootURL, isDirectory: isDirectory),
                      !(isDirectory && isNestedLinkedWorktree(url)) else { return nil }
                return ProjectDirectoryEntry(
                    url: directory.appendingPathComponent(url.lastPathComponent),
                    isDirectory: isDirectory
                )
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
            result[directory.standardizedFileURL.path] = entries
        }
        return result
    }

    private func scan(_ url: URL, rootURL: URL, visibilityRules: FileVisibilityRules, nestedWorktrees: inout [URL], isRoot: Bool = false) -> FileNode? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), isRoot || values.isSymbolicLink != true else { return nil }
        let isDirectory = values.isDirectory == true
        guard isRoot || !visibilityRules.isHidden(url, relativeTo: rootURL, isDirectory: isDirectory) else { return nil }
        guard isDirectory else {
            return FileNode(url: url, isDirectory: false, children: nil)
        }
        if !isRoot, isNestedLinkedWorktree(url) {
            nestedWorktrees.append(url)
            return nil
        }
        let childURLs = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
        let children = childURLs.compactMap { scan($0, rootURL: rootURL, visibilityRules: visibilityRules, nestedWorktrees: &nestedWorktrees) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return FileNode(url: url, isDirectory: true, children: children)
    }

    /// Mirrors Rust Core's `is_nested_linked_worktree`: a `.git` pointer file
    /// into `<main>/.git/worktrees/<id>` where `<main>` contains the directory.
    private func isNestedLinkedWorktree(_ directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(".git")
        guard let attributes = try? fileManager.attributesOfItem(atPath: marker.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 4 * 1024,
              let text = try? String(contentsOf: marker, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:") else { return false }
        let pointer = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !pointer.isEmpty else { return false }
        let gitDirectory = pointer.hasPrefix("/")
            ? URL(fileURLWithPath: pointer)
            : directory.appendingPathComponent(pointer).standardizedFileURL
        let worktrees = gitDirectory.deletingLastPathComponent()
        let commonDirectory = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees",
              commonDirectory.lastPathComponent == ".git" else { return false }
        let mainPath = commonDirectory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return directoryPath != mainPath && directoryPath.hasPrefix(mainPath.hasSuffix("/") ? mainPath : mainPath + "/")
    }
}
