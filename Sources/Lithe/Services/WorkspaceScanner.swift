import Foundation

struct WorkspaceScanner: Sendable {
    private let fileSystem: any WorkspaceFileSystem

    init(fileSystem: any WorkspaceFileSystem) {
        self.fileSystem = fileSystem
    }

    func snapshot(
        at rootURL: URL,
        rules: FileVisibilityRules = .default
    ) -> WorkspaceSnapshot {
        var indexedFiles: [URL] = []
        let root = makeNode(
            at: rootURL,
            indexedFiles: &indexedFiles,
            rules: rules,
            workspaceRoot: rootURL
        )
        return WorkspaceSnapshot(root: root, files: indexedFiles)
    }

    static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isReadableTextFile(_ url: URL) -> Bool {
        let textExtensions: Set<String> = [
            "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json",
            "jsx", "kt", "kts", "md", "m", "mm", "php", "plist", "properties", "py", "rb",
            "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
        ]
        return textExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.isEmpty
    }

    private func makeNode(
        at url: URL,
        indexedFiles: inout [URL],
        rules: FileVisibilityRules,
        workspaceRoot: URL
    ) -> FileNode {
        let metadata = fileSystem.metadata(for: url)

        guard metadata.isDirectory else {
            indexedFiles.append(url)
            return FileNode(url: url, isDirectory: false, children: nil)
        }

        let visibleURLs = fileSystem.contentsOfDirectory(at: url).filter { child in
            let childMetadata = fileSystem.metadata(for: child)
            guard !childMetadata.isSymbolicLink else { return false }
            return !rules.isHidden(
                child,
                relativeTo: workspaceRoot,
                isDirectory: childMetadata.isDirectory
            )
        }

        let sortedURLs = visibleURLs.sorted { lhs, rhs in
            let leftDirectory = fileSystem.metadata(for: lhs).isDirectory
            let rightDirectory = fileSystem.metadata(for: rhs).isDirectory
            if leftDirectory != rightDirectory { return leftDirectory }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        let children = sortedURLs.map {
            makeNode(
                at: $0,
                indexedFiles: &indexedFiles,
                rules: rules,
                workspaceRoot: workspaceRoot
            )
        }
        return FileNode(url: url, isDirectory: true, children: children)
    }
}
