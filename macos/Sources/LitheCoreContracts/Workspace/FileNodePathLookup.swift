import Foundation

/// Path-addressed reads and edits of a workspace tree.
///
/// Lookups follow the path one level at a time instead of scanning every node,
/// so their cost depends on the path depth and sibling counts, not on the
/// workspace size. The sidebar evaluates them on every render; a whole-tree
/// scan there showed up as most of the main thread's samples in issue #1245.
extension FileNode {
    /// Where a path sits relative to the rows the tree has loaded.
    package enum RowPlacement {
        /// The row that displays the path. `isExact` is false when the path is
        /// a collapsed middle package of that row.
        case displayed(FileNode, isExact: Bool)
        /// The path is below this directory row, whose children are unloaded.
        case belowUnloaded(FileNode)
        /// No loaded row leads to the path.
        case absent
    }

    /// Result of applying one file change to a tree.
    package enum TreeEdit {
        case unchanged
        case updated(FileNode)
        /// The change can affect how middle packages are compacted, or lands
        /// where the tree has no row; only re-listing reproduces the layout.
        case reload
    }

    package func placement(of url: URL) -> RowPlacement {
        guard let components = relativeComponents(of: url),
              let location = rowLocation(of: components[...]),
              let node = node(atIndices: location.indices[...]) else { return .absent }
        return location.isBelowUnloadedRow
            ? .belowUnloaded(node)
            : .displayed(node, isExact: location.isExact)
    }

    /// Tree row that displays `url`: the node itself, or the compact
    /// middle-package row whose collapsed ancestors include it.
    package func displayedNode(for url: URL) -> FileNode? {
        guard case .displayed(let node, _) = placement(of: url) else { return nil }
        return node
    }

    /// Node whose own URL is `url`. Collapsed middle packages are not nodes and
    /// return nil.
    package func node(exactlyAt url: URL) -> FileNode? {
        guard case .displayed(let node, true) = placement(of: url) else { return nil }
        return node
    }

    /// Files in tree order, sharing this tree's URL instances. Only loaded
    /// directories contribute.
    package var fileURLs: [URL] {
        var urls: [URL] = []
        appendFileURLs(to: &urls)
        return urls
    }

    /// Directory rows whose children are loaded, parents before children.
    package var loadedDirectoryRows: [FileNode] {
        var rows: [FileNode] = []
        appendLoadedDirectoryRows(to: &rows)
        return rows
    }

    /// Expanded directory rows that are visible but still unloaded. A row is
    /// visible when every row above it is expanded.
    package func unloadedRows(expandedPaths: Set<String>) -> [FileNode] {
        guard isDirectory, expandedPaths.contains(url.path) else { return [] }
        guard let children else { return [self] }
        return children.flatMap { $0.unloadedRows(expandedPaths: expandedPaths) }
    }

    /// Replaces the children of the directory row whose own URL is `url`.
    package func loadingChildren(_ children: [FileNode], intoRowAt url: URL) -> FileNode? {
        guard let components = relativeComponents(of: url),
              let location = rowLocation(of: components[...]),
              location.isExact, !location.isBelowUnloadedRow else { return nil }
        return updatingNode(atIndices: location.indices[...]) { directory in
            directory.isDirectory ? directory.replacingChildren(children) : nil
        }
    }

    /// Adds a file below the directory row that owns its parent path. Nothing
    /// changes when that directory has not been loaded.
    package func inserting(file url: URL) -> TreeEdit {
        switch placement(of: url.deletingLastPathComponent()) {
        case .belowUnloaded:
            return .unchanged
        case .absent, .displayed(_, isExact: false):
            return .reload
        case .displayed(let directory, isExact: true):
            guard directory.isDirectory else { return .reload }
            guard var children = directory.children else { return .unchanged }
            let name = url.lastPathComponent
            if children.contains(where: { !$0.isDirectory && $0.url.lastPathComponent == name }) {
                return .unchanged
            }
            let file = FileNode(url: url, isDirectory: false, children: nil)
            let position = children.firstIndex { Self.treeOrder(file, before: $0) } ?? children.endIndex
            children.insert(file, at: position)
            return loadingChildren(children, intoRowAt: directory.url).map(TreeEdit.updated) ?? .reload
        }
    }

    /// Removes a file row. Removing it can let its directory compact into a
    /// middle package, which needs a reload.
    package func removing(file url: URL) -> TreeEdit {
        guard case .displayed(let file, isExact: true) = placement(of: url), !file.isDirectory,
              case .displayed(let directory, isExact: true) = placement(of: url.deletingLastPathComponent()),
              var children = directory.children,
              let index = children.firstIndex(where: { !$0.isDirectory && $0.url == file.url })
        else { return .unchanged }
        children.remove(at: index)
        if directory.isInsideSourceRoot, children.count == 1, children[0].isDirectory {
            return .reload
        }
        return loadingChildren(children, intoRowAt: directory.url).map(TreeEdit.updated) ?? .reload
    }

    // MARK: - Path walking

    private struct RowLocation {
        var indices: [Int]
        /// False when the path names a collapsed middle package of the row.
        var isExact: Bool
        /// True when the walk stopped at an unloaded directory row before the
        /// path ended; `indices` then lead to that row.
        var isBelowUnloadedRow = false
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
        guard let children else {
            return isDirectory ? RowLocation(indices: [], isExact: false, isBelowUnloadedRow: true) : nil
        }
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
            guard var deeper = child.rowLocation(of: remaining) else { return nil }
            deeper.indices.insert(index, at: 0)
            return deeper
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

    private func appendLoadedDirectoryRows(to rows: inout [FileNode]) {
        guard isDirectory, let children else { return }
        rows.append(self)
        for child in children {
            child.appendLoadedDirectoryRows(to: &rows)
        }
    }

    /// Matches the snapshot scan: directories first, then lowercased names.
    private static func treeOrder(_ left: FileNode, before right: FileNode) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        return left.firstPathComponent.lowercased() < right.firstPathComponent.lowercased()
    }
}
