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
        var files: [URL] = []
        guard let root = scan(rootURL, rootURL: rootURL, visibilityRules: visibilityRules, files: &files, isRoot: true) else { return nil }
        return WorkspaceSnapshot(root: root, files: files)
    }

    private func scan(_ url: URL, rootURL: URL, visibilityRules: FileVisibilityRules, files: inout [URL], isRoot: Bool = false) -> FileNode? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), isRoot || values.isSymbolicLink != true else { return nil }
        let isDirectory = values.isDirectory == true
        guard isRoot || !visibilityRules.isHidden(url, relativeTo: rootURL, isDirectory: isDirectory) else { return nil }
        guard isDirectory else {
            files.append(url)
            return FileNode(url: url, isDirectory: false, children: nil)
        }
        let childURLs = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
        let children = childURLs.compactMap { scan($0, rootURL: rootURL, visibilityRules: visibilityRules, files: &files) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return FileNode(url: url, isDirectory: true, children: children)
    }
}
