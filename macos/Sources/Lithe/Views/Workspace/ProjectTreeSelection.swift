import Foundation
import LitheCoreContracts

/// Selection follows the displayed tree order, including only expanded children.
struct ProjectTreeSelection: Equatable {
    private(set) var paths: Set<String> = []
    private(set) var anchorPath: String?
    private(set) var focusedPath: String?

    mutating func select(_ path: String, visiblePaths: [String], extending: Bool, toggling: Bool) {
        focusedPath = path
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

    mutating func selectForContextMenu(_ path: String) {
        focusedPath = path
        guard !paths.contains(path) else { return }
        paths = [path]
        anchorPath = path
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

    static func visibleNodes(in root: FileNode, expandedPaths: Set<String>) -> [FileNode] {
        var nodes = [root]
        if root.isDirectory, expandedPaths.contains(root.url.path) {
            for child in root.children ?? [] {
                nodes += visibleNodes(in: child, expandedPaths: expandedPaths)
            }
        }
        return nodes
    }
}
