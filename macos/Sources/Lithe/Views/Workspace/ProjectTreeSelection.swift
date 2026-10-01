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

    /// ⌘A selects the visible items that share the focused item's parent
    /// directory, including expanded descendants. The focus stays put so a
    /// repeated ⌘A keeps the same scope.
    mutating func selectAll(visiblePaths: [String], rootPath: String) {
        let scope = focusedPath.flatMap { $0 == rootPath ? nil : ($0 as NSString).deletingLastPathComponent }
        let scoped = scope.map { scope in visiblePaths.filter { $0.hasPrefix(scope + "/") } } ?? visiblePaths
        paths = Set(scoped)
        anchorPath = scoped.first
        if focusedPath.map({ !paths.contains($0) }) ?? true { focusedPath = scoped.last }
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
