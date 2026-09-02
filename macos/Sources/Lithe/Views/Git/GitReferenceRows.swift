import Foundation
import LitheGitModule

/// One visible line of the Git log's reference tree.
///
/// The tree used to render as a recursive `-> AnyView` function, which erased
/// every level's type, blocked `LazyVStack`, and forced the whole tree to
/// re-evaluate whenever `GitLogView` re-ran. Flattening to rows makes each line
/// independently comparable and lazily rendered.
struct GitReferenceRow: Identifiable, Equatable {
    enum Content: Equatable {
        /// A branch, remote branch, or tag the user can act on.
        case reference(GitReference)
        /// A path segment shared by several references, such as `feature` in
        /// `feature/a` and `feature/b`. `key` is the collapse-state key.
        case group(key: String, isCollapsed: Bool)
    }

    let id: String
    /// The last path component, which is what the row displays.
    let name: String
    /// Nesting level, used only for the row's leading indent.
    let depth: Int
    let content: Content
}

/// Flattens references into the visible rows of one section, in render order.
enum GitReferenceRowsBuilder {
    /// - Parameters:
    ///   - references: Already filtered to a single `kind` by the caller.
    ///   - collapsedGroups: Keys of groups whose children are hidden.
    static func rows(
        from references: [GitReference],
        kind: GitReferenceKind,
        collapsedGroups: Set<String>
    ) -> [GitReferenceRow] {
        var rows: [GitReferenceRow] = []
        append(
            GitReferenceTreeNode.build(from: references),
            kind: kind,
            depth: 0,
            collapsedGroups: collapsedGroups,
            into: &rows
        )
        return rows
    }

    private static func append(
        _ nodes: [GitReferenceTreeNode],
        kind: GitReferenceKind,
        depth: Int,
        collapsedGroups: Set<String>,
        into rows: inout [GitReferenceRow]
    ) {
        for node in nodes {
            // A node can be both: `feature` may be a branch and also the prefix
            // of `feature/x`, in which case it emits a reference row and a group
            // row at the same depth.
            if let reference = node.reference {
                rows.append(
                    GitReferenceRow(
                        id: "reference:" + node.path,
                        name: node.name,
                        depth: depth,
                        content: .reference(reference)
                    )
                )
            }

            guard !node.children.isEmpty else { continue }
            let key = "\(kind.rawValue):\(node.path)"
            let isCollapsed = collapsedGroups.contains(key)
            rows.append(
                GitReferenceRow(
                    id: "group:" + node.path,
                    name: node.name,
                    depth: depth,
                    content: .group(key: key, isCollapsed: isCollapsed)
                )
            )

            guard !isCollapsed else { continue }
            append(
                node.children,
                kind: kind,
                depth: depth + 1,
                collapsedGroups: collapsedGroups,
                into: &rows
            )
        }
    }
}

/// Intermediate tree used only to group references by their `/`-separated path
/// before flattening.
struct GitReferenceTreeNode: Identifiable {
    let path: String
    let name: String
    let reference: GitReference?
    let children: [GitReferenceTreeNode]

    var id: String { path }

    static func build(from references: [GitReference]) -> [GitReferenceTreeNode] {
        let root = MutableGitReferenceTreeNode(name: "", path: "")

        for reference in references {
            let components = reference.shortName
                .split(separator: "/")
                .map(String.init)
            guard !components.isEmpty else { continue }

            var node = root
            var pathComponents: [String] = []
            for component in components {
                pathComponents.append(component)
                if node.children[component] == nil {
                    node.children[component] = MutableGitReferenceTreeNode(
                        name: component,
                        path: pathComponents.joined(separator: "/")
                    )
                }
                node = node.children[component]!
            }
            node.reference = reference
        }

        return makeNodes(from: root)
    }

    private static func makeNodes(from node: MutableGitReferenceTreeNode) -> [GitReferenceTreeNode] {
        node.children.values
            .map { child in
                GitReferenceTreeNode(
                    path: child.path,
                    name: child.name,
                    reference: child.reference,
                    children: makeNodes(from: child)
                )
            }
            // Leaves before folders, then natural order, so the list is stable
            // across rebuilds of the unordered child dictionary.
            .sorted { lhs, rhs in
                if (lhs.reference != nil) != (rhs.reference != nil) {
                    return lhs.reference != nil
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

private final class MutableGitReferenceTreeNode {
    let name: String
    let path: String
    var reference: GitReference?
    var children: [String: MutableGitReferenceTreeNode] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}
