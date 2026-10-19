import Foundation

/// Path-addressed reads and edits of a workspace tree.
///
/// Lookups follow the path one level at a time instead of scanning every node,
/// so their cost depends on the path depth and sibling counts, not on the
/// workspace size. The sidebar evaluates them on every render; a whole-tree
/// scan there showed up as most of the main thread's samples in issue #1245.
extension FileNode {
    /// Tree row that displays `url`: the node itself, or the compact
    /// middle-package row whose collapsed ancestors include it.
    package func displayedNode(for url: URL) -> FileNode? {
        guard let components = relativeComponents(of: url),
              let location = rowLocation(of: components[...]) else { return nil }
        return node(atIndices: location.indices[...])
    }

    /// Node whose own URL is `url`. Collapsed middle packages are not nodes and
    /// return nil.
    package func node(exactlyAt url: URL) -> FileNode? {
        guard let components = relativeComponents(of: url),
              let location = rowLocation(of: components[...]),
              location.isExact else { return nil }
        return node(atIndices: location.indices[...])
    }

    /// Files in tree order, sharing this tree's URL instances.
    package var fileURLs: [URL] {
        var urls: [URL] = []
        appendFileURLs(to: &urls)
        return urls
    }

    /// Adds a file below the directory row that owns its parent path.
    ///
    /// Returns nil when that directory is not its own row, or when adding the
    /// file could change how middle packages are compacted. Callers rescan in
    /// that case, because only a scan reproduces the full layout rules.
    package func inserting(file url: URL) -> FileNode? {
        let parentURL = url.deletingLastPathComponent()
        guard let components = relativeComponents(of: parentURL),
              let location = rowLocation(of: components[...]),
              location.isExact else { return nil }
        return updatingNode(atIndices: location.indices[...]) { directory in
            guard directory.isDirectory, var children = directory.children else { return nil }
            let name = url.lastPathComponent
            if children.contains(where: { !$0.isDirectory && $0.url.lastPathComponent == name }) {
                return directory
            }
            let file = FileNode(url: url, isDirectory: false, children: nil)
            let position = children.firstIndex { Self.treeOrder(file, before: $0) } ?? children.endIndex
            children.insert(file, at: position)
            return directory.replacingChildren(children)
        }
    }

    /// Removes a file row. Returns nil when the file is not its own row or when
    /// removing it would let its directory compact into a middle package.
    package func removing(file url: URL) -> FileNode? {
        guard let components = relativeComponents(of: url),
              let location = rowLocation(of: components[...]),
              location.isExact,
              let fileIndex = location.indices.last else { return nil }
        return updatingNode(atIndices: location.indices.dropLast()) { directory in
            guard var children = directory.children,
                  children.indices.contains(fileIndex),
                  !children[fileIndex].isDirectory else { return nil }
            children.remove(at: fileIndex)
            if directory.isInsideSourceRoot, children.count == 1, children[0].isDirectory {
                return nil
            }
            return directory.replacingChildren(children)
        }
    }

    // MARK: - Path walking

    private struct RowLocation {
        var indices: [Int]
        /// False when the path names a collapsed middle package of the row.
        var isExact: Bool
    }

    private func relativeComponents(of url: URL) -> [String]? {
        let rootPath = self.url.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        if targetPath == rootPath { return [] }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else { return nil }
        return targetPath.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    private func rowLocation(of components: ArraySlice<String>) -> RowLocation? {
        guard let first = components.first else { return RowLocation(indices: [], isExact: true) }
        guard let children else { return nil }
        for (index, child) in children.enumerated() where child.firstPathComponent == first {
            let chain = child.collapsedAncestorPaths.map { ($0 as NSString).lastPathComponent }
                + [child.url.lastPathComponent]
            var remaining = components.dropFirst()
            for name in chain.dropFirst() {
                guard let next = remaining.first else {
                    return RowLocation(indices: [index], isExact: false)
                }
                guard next == name else { return nil }
                remaining = remaining.dropFirst()
            }
            guard let deeper = child.rowLocation(of: remaining) else { return nil }
            return RowLocation(indices: [index] + deeper.indices, isExact: deeper.isExact)
        }
        return nil
    }

    private var firstPathComponent: String {
        collapsedAncestorPaths.first.map { ($0 as NSString).lastPathComponent }
            ?? url.lastPathComponent
    }

    private func node(atIndices indices: ArraySlice<Int>) -> FileNode? {
        guard let index = indices.first else { return self }
        guard let children, children.indices.contains(index) else { return nil }
        return children[index].node(atIndices: indices.dropFirst())
    }

    private func updatingNode(
        atIndices indices: ArraySlice<Int>,
        _ transform: (FileNode) -> FileNode?
    ) -> FileNode? {
        guard let index = indices.first else { return transform(self) }
        guard var children, children.indices.contains(index),
              let child = children[index].updatingNode(atIndices: indices.dropFirst(), transform)
        else { return nil }
        children[index] = child
        return replacingChildren(children)
    }

    private func replacingChildren(_ children: [FileNode]) -> FileNode {
        FileNode(
            url: url,
            isDirectory: isDirectory,
            children: children,
            collapsedAncestorPaths: collapsedAncestorPaths,
            isInsideSourceRoot: isInsideSourceRoot
        )
    }

    private func appendFileURLs(to urls: inout [URL]) {
        guard isDirectory else {
            urls.append(url)
            return
        }
        for child in children ?? [] {
            child.appendFileURLs(to: &urls)
        }
    }

    /// Matches the snapshot scan: directories first, then lowercased names.
    private static func treeOrder(_ left: FileNode, before right: FileNode) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        return left.firstPathComponent.lowercased() < right.firstPathComponent.lowercased()
    }
}
