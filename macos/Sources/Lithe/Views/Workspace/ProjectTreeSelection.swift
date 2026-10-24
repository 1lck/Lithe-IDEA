import Foundation
import LitheCoreContracts

typealias ProjectTreeNavigationKey = LitheTreeListNavigationKey

/// Selection follows the displayed tree order, including only expanded children.
struct ProjectTreeSelection: Equatable {
    private(set) var paths: Set<String> = []
    private(set) var anchorPath: String?
    private(set) var focusedPath: String?

    mutating func select(_ path: String, visiblePaths: @autoclosure () -> [String], extending: Bool, toggling: Bool) {
        focusedPath = path
        let visiblePaths = extending ? visiblePaths() : []
        let order = extending ? visiblePaths : [path]
        paths = LitheTreeListSelection.select(
            path, in: order, selected: paths, anchor: anchorPath,
            extending: extending, toggling: toggling)
        if !extending || anchorPath == nil || !order.contains(anchorPath!) { anchorPath = path }
    }

    /// Only explicitly selected rows are highlighted; folders remain atomic action targets.
    func covers(_ path: String) -> Bool { paths.contains(path) }

    mutating func selectForContextMenu(_ path: String) {
        focusedPath = path
        guard !paths.contains(path) else { return }
        paths = [path]
        anchorPath = path
    }

    /// Starting a drag on an existing selection must not collapse the group.
    mutating func selectForDragging(_ path: String) {
        guard !paths.contains(path) else { return }
        select(path, visiblePaths: [], extending: false, toggling: false)
    }

    func draggedURLs(excluding root: URL) -> [URL] {
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return paths.sorted().filter { $0 != root.path && $0.hasPrefix(prefix) }.compactMap { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" {
                if parent != root.path && paths.contains(parent) { return nil }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return URL(fileURLWithPath: path)
        }
    }

    mutating func retain(visiblePaths: [String]) {
        let visible = Set(visiblePaths)
        paths.formIntersection(visible)
        if let anchorPath, !visible.contains(anchorPath) { self.anchorPath = nil }
        if let focusedPath, !visible.contains(focusedPath) { self.focusedPath = nil }
    }

    /// ⌘A selects the focused row's siblings in the displayed tree, so a
    /// folder selects the items beside it rather than its own contents. Batch
    /// actions already include a selected folder's descendants. With no focus,
    /// or focus on the project row, the project's top-level items are selected.
    mutating func selectAll(in root: FileNode) {
        let parent = focusedPath.flatMap { Self.displayedParent(of: $0, in: root) } ?? root
        let siblings = (parent.children ?? []).map(\.url.path)
        guard let first = siblings.first else { return }
        paths = Set(siblings)
        anchorPath = first
        if focusedPath.map({ !paths.contains($0) }) ?? true { focusedPath = first }
    }

    /// Uses tree structure instead of path components because compacted Java
    /// packages display below an ancestor that is not their filesystem parent.
    private static func displayedParent(of path: String, in node: FileNode) -> FileNode? {
        for child in node.children ?? [] {
            if child.url.path == path { return node }
            if let parent = displayedParent(of: path, in: child) { return parent }
        }
        return nil
    }

    struct VisibleRow: Identifiable {
        /// The row's node without its subtree. Row views can outlive a
        /// snapshot, and a full node would keep that snapshot's whole tree
        /// (every URL of a large workspace) alive.
        let node: FileNode
        let depth: Int
        var id: String { node.url.path }

        init(node: FileNode, depth: Int) {
            self.node = FileNode(
                url: node.url,
                isDirectory: node.isDirectory,
                children: node.children?.isEmpty == true ? [] : nil,
                collapsedAncestorPaths: node.collapsedAncestorPaths,
                isInsideSourceRoot: node.isInsideSourceRoot
            )
            self.depth = depth
        }
    }

    /// IDEA expands a sole directory child, preserving each row and stopping at files or siblings.
    static func expandingSingleDirectoryChains(from paths: Set<String>, in root: FileNode,
                                               expandedPaths: Set<String>) -> Set<String> {
        var expanded = expandedPaths
        for path in paths where expanded.contains(path) {
            var current = root.node(exactlyAt: URL(fileURLWithPath: path))
            for _ in 0..<64 {
                guard let children = current?.children, children.count == 1,
                      let child = children.first, child.isDirectory,
                      let childRows = child.children, !childRows.isEmpty,
                      !child.url.lastPathComponent.hasPrefix(".") else { break }
                expanded.insert(child.url.path)
                expanded.formUnion(child.collapsedAncestorPaths)
                current = child
            }
        }
        return expanded
    }

    static func visibleRows(in root: FileNode, expandedPaths: Set<String>) -> [VisibleRow] {
        var rows: [VisibleRow] = []
        func append(_ node: FileNode, depth: Int) {
            rows.append(VisibleRow(node: node, depth: depth))
            if node.isDirectory, expandedPaths.contains(node.url.path) {
                for child in node.children ?? [] { append(child, depth: depth + 1) }
            }
        }
        append(root, depth: 0)
        return rows
    }

    static func visibleNodes(in root: FileNode, expandedPaths: Set<String>) -> [FileNode] {
        visibleRows(in: root, expandedPaths: expandedPaths).map(\.node)
    }

    /// Navigation uses displayed depth, including compacted packages, rather
    /// than filesystem parents. Moving selection never opens an editor.
    mutating func navigate(_ key: ProjectTreeNavigationKey, in root: FileNode,
                           expandedPaths: inout Set<String>, extending: Bool) {
        let rows = Self.visibleRows(in: root, expandedPaths: expandedPaths)
        guard !rows.isEmpty else { return }
        guard let index = rows.firstIndex(where: { $0.id == focusedPath }) else {
            select(rows[0].id, visiblePaths: [], extending: false, toggling: false)
            return
        }
        let hierarchy = rows.map {
            LitheTreeListHierarchy(
                depth: $0.depth,
                isBranch: $0.node.isDirectory && $0.node.children?.isEmpty != true,
                isExpanded: expandedPaths.contains($0.id))
        }
        switch LitheTreeListNavigation.resolve(key, current: index, rows: hierarchy) {
        case .expand(let target, let expanded):
            let row = rows[target]
            if expanded {
                expandedPaths.insert(row.id)
                expandedPaths.formUnion(row.node.collapsedAncestorPaths)
            } else {
                expandedPaths.remove(row.id)
                expandedPaths.subtract(row.node.collapsedAncestorPaths)
            }
        case .select(let target):
            select(
                rows[target].id, visiblePaths: rows.map(\.id),
                extending: extending && (key == .up || key == .down), toggling: false)
        case nil: break
        }
    }
}
