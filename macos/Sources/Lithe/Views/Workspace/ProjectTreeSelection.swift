import Foundation
import LitheCoreContracts

enum ProjectTreeNavigationKey: UInt16 {
    case left = 123, right = 124, down = 125, up = 126
}

/// Selection follows the displayed tree order, including only expanded children.
struct ProjectTreeSelection: Equatable {
    private(set) var paths: Set<String> = []
    private(set) var anchorPath: String?
    private(set) var focusedPath: String?

    mutating func select(_ path: String, visiblePaths: @autoclosure () -> [String], extending: Bool, toggling: Bool) {
        focusedPath = path
        let visiblePaths = extending ? visiblePaths() : []
        if extending, let anchorPath,
           let start = visiblePaths.firstIndex(of: anchorPath),
           let end = visiblePaths.firstIndex(of: path) {
            let range = Set(visiblePaths[min(start, end)...max(start, end)])
            paths = toggling ? paths.union(range) : range
        } else if toggling {
            if !paths.insert(path).inserted { paths.remove(path) }
            anchorPath = path
        } else {
            paths = [path]
            anchorPath = path
        }
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
        let node: FileNode
        let depth: Int
        var id: String { node.url.path }
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
        let row = rows[index]
        var target = index
        switch key {
        case .up: target = max(0, index - 1)
        case .down: target = min(rows.count - 1, index + 1)
        case .right:
            guard row.node.isDirectory else { return }
            if expandedPaths.insert(row.id).inserted {
                expandedPaths.formUnion(row.node.collapsedAncestorPaths)
                return
            }
            if index + 1 < rows.count, rows[index + 1].depth > row.depth { target = index + 1 }
        case .left:
            if row.node.isDirectory, expandedPaths.remove(row.id) != nil {
                row.node.collapsedAncestorPaths.forEach { expandedPaths.remove($0) }
                return
            }
            if let parent = rows[..<index].lastIndex(where: { $0.depth < row.depth }) { target = parent }
        }
        select(rows[target].id, visiblePaths: rows.map(\.id),
               extending: extending && (key == .up || key == .down), toggling: false)
    }
}
