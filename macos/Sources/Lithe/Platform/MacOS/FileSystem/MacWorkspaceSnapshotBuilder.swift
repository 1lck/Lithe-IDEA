import Foundation
import LitheCoreContracts

/// Native recursive scan of a workspace. Production listings come from
/// `workspace.listDirectories`; the plugin file service reuses the nested
/// worktree check below.
struct FileSystemWorkspaceSnapshotBuilder {
    private let fileManager: FileManager
    private let core: RustCoreBridge

    init(fileManager: FileManager = .default, core: RustCoreBridge = RustCoreBridge()) {
        self.fileManager = fileManager
        self.core = core
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        let rootURL = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        var nestedWorktrees: [URL] = []
        guard let root = scan(rootURL, rootURL: rootURL, visibilityRules: visibilityRules, nestedWorktrees: &nestedWorktrees, isRoot: true) else { return nil }
        return WorkspaceSnapshot(root: root, files: root.fileURLs, nestedWorktrees: nestedWorktrees.sorted { $0.path < $1.path })
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
        let scanned = childURLs.compactMap { scan($0, rootURL: rootURL, visibilityRules: visibilityRules, nestedWorktrees: &nestedWorktrees) }
        // Sibling order comes from Core, like every Project tree listing.
        guard let order = core.orderEntries(scanned.map {
            RustCoreBridge.OrderedEntry(name: $0.name, isDirectory: $0.isDirectory)
        }) else { return nil }
        return FileNode(url: url, isDirectory: true, children: order.map { scanned[$0] })
    }

    /// Mirrors Rust Core's `is_nested_linked_worktree`: a `.git` pointer file
    /// into `<main>/.git/worktrees/<id>` where `<main>` contains the directory.
    /// `MacPluginWorkspaceFileService` reuses it so plugin listings omit the
    /// same nested worktrees as the Project view.
    func isNestedLinkedWorktree(_ directory: URL) -> Bool {
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
